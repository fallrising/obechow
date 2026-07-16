# Twitter Deck MVP — 單機 CI/CD Runbook

> **Repo:** [github.com/fallrising/obechow](https://github.com/fallrising/obechow)  
> **目標路徑：** `git push` → GitHub Actions build image → push GHCR → SSH 進 VPS pull + restart → `https://deck.<你的網域>` 看到新版。

---

## 前置假設

- VPS 是 Ubuntu 22.04+ / Debian，用 Docker CE（不是裸 containerd）
- 有一個網域，DNS 掛在 Cloudflare
- GitHub repo（private 也可以，GHCR 免費）
- GitHub Actions runner 能 SSH 到 VPS（公網 port 或 Tailscale 二選一，Phase 4 各有寫法）

## 目錄規劃

所有東西都在 `/srv` 下，好備份、好遷移：

```
/srv
├── edge/
│   └── compose.yml          # Traefik（ingress controller 替身）
├── apps/
│   └── twitter-deck/
│       ├── compose.yml      # desired state
│       └── data/            # SQLite 落地處（bind mount）
└── deploy.sh                # CD 的最後一哩
```

---

## Phase 0 — VPS 一次性準備

```bash
# Docker（已裝可跳過）
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # 重新登入生效

# 共用 edge network：Traefik 和所有 app 都掛這張網
docker network create edge

# 目錄
sudo mkdir -p /srv/edge /srv/apps/twitter-deck/data
sudo chown -R $USER:$USER /srv
```

> **註：** `docker` group 等同 root。單人 VPS 可接受；要收緊的話 Phase 4 末尾有 `authorized_keys` 鎖指令的做法。

---

## Phase 1 — Traefik（Ingress Controller）

`/srv/edge/compose.yml`：

```yaml
services:
  traefik:
    image: traefik:v3
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --certificatesresolvers.le.acme.email=you@example.com
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
    networks:
      - edge

networks:
  edge:
    external: true
```

```bash
cd /srv/edge && docker compose up -d
```

**DNS：** 在 Cloudflare 加 `deck.<網域>` A record 指向 VPS IP，**先灰雲（DNS only）**，讓 HTTP-01 challenge 能直連通過。之後要開橘雲（CF proxy），把 `httpchallenge` 那行換成 DNS-01：

```yaml
      # 取代 httpchallenge 那一行：
      - --certificatesresolvers.le.acme.dnschallenge.provider=cloudflare
    environment:
      - CF_DNS_API_TOKEN=<有 Zone.DNS edit 權限的 token>
```

**如果 80/443 已被既有 nginx 佔用**，三選一：

1. **最快打通：** 不裝 Traefik，app compose 改成 `ports: ["127.0.0.1:18080:8080"]`，手寫一份 nginx proxy conf 指向 `127.0.0.1:18080`。CI/CD 流程完全不變，只是 ingress 這格暫時還是手動 nginx。
2. Traefik 先聽 `8081/8444` 測通，之後再搬家。
3. 一次到位：把既有站台遷進 Traefik（每站一段 file provider config 或容器化）。

---

## Phase 2 — 專案骨架（本 repo 已實作）

Repo 結構：

```
obechow/
├── backend/                  # Spring Boot 3.x, Java 17, Maven
├── frontend/                 # Vite + React + TS + Tailwind + shadcn/ui
├── Dockerfile                # Phase 3 已完成
├── .dockerignore             # Phase 3 已完成
└── .github/workflows/deploy.yml  # Phase 4 待加
```

### 已實作功能

**Backend**

- Dependencies：`spring-boot-starter-web`、`spring-boot-starter-data-jpa`、`sqlite-jdbc`、`hibernate-community-dialects`
- `application.yml`：SQLite WAL、`SQLiteDialect`、`ddl-auto: update`、port 8080
- Entity `Post`：`id`、`author`、`content`（max 280）、`createdAt`
- REST API：
  - `GET /api/health` → `{"status":"ok"}`
  - `GET /api/posts?author=&q=` → 最新 50 則，可選作者 / 關鍵字篩選
  - `POST /api/posts` → 201 建立貼文
- SPA fallback：非 `/api` 的 GET（無副檔名）轉發到 `/index.html`

**Frontend**

- Deck 橫向欄位：**All**、**Mine**、**Search**
- Compose box（作者 + 內容，280 字計數器）
- 每欄每 5 秒輪詢 `GET /api/posts`
- shadcn/ui：Card、Button、Input、Textarea
- `vite.config.ts`：dev proxy `/api` → `http://localhost:8080`，build 輸出 `frontend/dist`

### 本地驗證（過了才進 Phase 3）

```bash
cd backend  && DB_PATH=../data/app.db mvn spring-boot:run
cd frontend && npm install && npm run dev
# http://localhost:5173 發文、看到列表
```

---

## Phase 3 — Dockerfile（單一 image）

`Dockerfile`（repo 根目錄）：

```dockerfile
# syntax=docker/dockerfile:1

# ---- frontend build ----
FROM node:22-alpine AS frontend-build
WORKDIR /frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
RUN npm run build

# ---- backend build ----
FROM maven:3.9-eclipse-temurin-17 AS backend-build
WORKDIR /backend
COPY backend/pom.xml ./
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline
COPY backend/src ./src
COPY --from=frontend-build /frontend/dist ./src/main/resources/static
RUN mvn --batch-mode --no-transfer-progress -DskipTests package

# ---- runtime ----
FROM eclipse-temurin:17-jre-alpine AS runtime
WORKDIR /app
COPY --from=backend-build /backend/target/skan-backend-*.jar app.jar
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
```

`.dockerignore`：

```
**/node_modules
**/target
**/dist
.git
.github
.agents
.codex
.idea
.vscode
data
*.log
```

Dockerfile 把前端 build 產物複製到 `src/main/resources/static`，Spring Boot 透過預設的 classpath resource handler serve 靜態檔；`SpaFallbackFilter` 負責深層 SPA 路由。

本地整包測試：

```bash
docker build -t obechow:dev .
docker run --rm -p 8080:8080 -v "$PWD/data:/data" -e DB_PATH=/data/app.db obechow:dev
curl -s localhost:8080/api/health   # {"status":"ok"}
# 瀏覽器開 localhost:8080，前端應該由 Spring 直接吐出來
```

---

## Phase 4 — GitHub Actions → GHCR

`.github/workflows/deploy.yml`：

```yaml
name: build-and-deploy
on:
  push:
    branches: [main]

env:
  IMAGE: ghcr.io/fallrising/obechow   # 必須全小寫

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.IMAGE }}:latest
            ${{ env.IMAGE }}:${{ github.sha }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Deploy over SSH
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_KEY }}
          script: /srv/deploy.sh twitter-deck ${{ github.sha }}
```

### SSH 鑰匙與 secrets

```bash
# 本機產一把專用 deploy key
ssh-keygen -t ed25519 -f deploy_key -C "gha-deploy" -N ""
# 公鑰 → VPS 的 ~/.ssh/authorized_keys
# 私鑰 → repo Settings → Secrets → SSH_KEY
# 另外設 SSH_HOST（IP 或域名）、SSH_USER
```

### Tailscale 變體

SSH 只開在 tailnet 時，把 deploy job 換成：

```yaml
  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
      - uses: appleboy/ssh-action@v1
        with:
          host: <vps 的 MagicDNS 名或 100.x IP>
          username: ${{ secrets.SSH_USER }}
          key: ${{ secrets.SSH_KEY }}
          script: /srv/deploy.sh twitter-deck ${{ github.sha }}
```

**前置：** Tailscale admin 建 OAuth client（勾 `auth_keys` scope、綁 `tag:ci`），ACL 允許 `tag:ci` → VPS 的 22 port。runner 節點是 ephemeral，跑完自動消失。

### 選配加固

限制這把 key 只能跑部署，在 VPS `authorized_keys` 該行前加：

```
command="/srv/deploy.sh twitter-deck \"$(echo $SSH_ORIGINAL_COMMAND | awk '{print $NF}')\"",no-port-forwarding,no-pty
```

MVP 階段可以先不管，打通再說。

---

## Phase 5 — VPS 端：app compose + deploy 腳本

`/srv/apps/twitter-deck/compose.yml`：

```yaml
services:
  app:
    image: ghcr.io/fallrising/obechow:${TAG:-latest}
    restart: unless-stopped
    environment:
      - DB_PATH=/data/app.db
    volumes:
      - ./data:/data
    networks:
      - edge
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/api/health"]
      interval: 30s
      timeout: 3s
      retries: 3
    labels:
      - traefik.enable=true
      - traefik.http.routers.tdeck.rule=Host(`deck.example.com`)
      - traefik.http.routers.tdeck.entrypoints=websecure
      - traefik.http.routers.tdeck.tls.certresolver=le
      - traefik.http.services.tdeck.loadbalancer.server.port=8080

networks:
  edge:
    external: true
```

`/srv/deploy.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: deploy.sh <app> [tag]}"
TAG="${2:-latest}"

cd "/srv/apps/${APP}"
export TAG
docker compose pull
docker compose up -d
docker image prune -f

echo "deployed ${APP} @ ${TAG}"
```

```bash
chmod +x /srv/deploy.sh
```

### GHCR 拉取授權

Package 預設 private：GitHub 開一個 PAT，只勾 `read:packages`，在 VPS 上用 deploy 那個使用者登入一次（存在 `~/.docker/config.json`）：

```bash
echo <PAT> | docker login ghcr.io -u fallrising --password-stdin
```

或者第一次 push 後把 package 設成 public，就免登入。

---

## Phase 6 — 首次部署與驗收

1. `git push origin main`
2. 看 Actions：build job 綠 → deploy job 綠（第一次若 deploy 比 VPS 設定先跑而失敗，補完 Phase 5 後 re-run 即可）
3. 開 `https://deck.<網域>`，發一篇文
4. **驗收核心：** 改一行前端文案 → push → 約 2–4 分鐘 → 重新整理看到變更。這條路通了，MVP 就算完成。

### 日常操作

```bash
# 看 app log
cd /srv/apps/twitter-deck && docker compose logs -f

# 看 Traefik 在幹嘛
cd /srv/edge && docker compose logs -f

# 回滾到任意舊版（GHCR 上每個 commit 都有 sha tag）
/srv/deploy.sh twitter-deck <舊的 git sha>
```

---

## 打通之後的補件方向

照 K8s 缺什麼補什麼：

| 方向 | 說明 |
|------|------|
| **零停機** | 目前 `up -d` 是 recreate，有幾秒 downtime。下一步是 healthcheck + 起新殺舊（compose 的 `--wait` + 雙 replica，或 Traefik 權重切換）—— 自製 rolling update。 |
| **push 改 pull（GitOps）** | 把「Actions SSH 進來推」換成 VPS 上常駐 reconcile loop —— 定期比對 GHCR tag / git repo compose 與本機實際狀態，不一致就對齊。懶人現成品是 Watchtower。 |
| **SQLite 備份** | Litestream 常駐複寫到 Cloudflare R2，一個 sidecar container 搞定，災難復原就是從 R2 restore。 |
| **可觀測性** | 先上 Dozzle（看 log）+ Beszel（看資源），都是單容器級的輕量件。 |

---

## 實作進度對照

| Phase | 狀態 | 說明 |
|-------|------|------|
| Phase 0 | ⬜ VPS 手動 | Docker、edge network、`/srv` 目錄 |
| Phase 1 | ⬜ VPS 手動 | Traefik + DNS |
| Phase 2 | ✅ 完成 | 本 repo 後端 + 前端 MVP |
| Phase 3 | ✅ 完成 | `Dockerfile`、`.dockerignore`；本地 image smoke test 通過 |
| Phase 4 | ⬜ 待做 | `.github/workflows/deploy.yml` + secrets |
| Phase 5 | ⬜ VPS 手動 | compose + `deploy.sh` + GHCR login |
| Phase 6 | ⬜ 待驗收 | 首次 push → 線上看到新版 |
