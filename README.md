> ## ⚠️ 此 repository 已退役（2026-09-04）
>
> 內容已遷移至 [`newclear`](https://github.com/fallrising/newclear) 的 [`products/phark/docs/legacy-obechow`](https://github.com/fallrising/newclear/tree/main/products/phark/docs/legacy-obechow)。
>
> 本 repository 保留為**唯讀歷史存放地**——完整 git 歷史仍在此處,
> 但新的開發請至後繼者。

---

# Obechow (Skan)

A minimal Twitter deck clone: horizontally scrollable columns for browsing and posting short messages.

**Repository:** [github.com/fallrising/obechow](https://github.com/fallrising/obechow)

## Stack

| Layer    | Tech |
|----------|------|
| Backend  | Spring Boot 3.3+, Java 17, Maven, JPA, SQLite |
| Frontend | Vite, React, TypeScript, Tailwind CSS, shadcn/ui |

## Project layout

```
.
├── backend/     # Spring Boot REST API
├── frontend/    # Vite + React SPA
├── Dockerfile   # Single production image
├── .github/     # Pull-request validation and main-branch delivery
├── ops/         # Versioned single-VPS Compose and deploy entrypoint
├── tests/ops/   # Hermetic deployment contract tests
└── data/        # SQLite database (created at runtime, gitignored)
```

## Prerequisites

- Java 17+
- Maven 3.9+
- Node.js 20.19+ or 22.12+

## Quick start

### 1. Backend

```bash
cd backend
DB_PATH=../data/app.db mvn spring-boot:run
```

The API listens on **http://localhost:8080**.

### 2. Frontend

In a second terminal:

```bash
cd frontend
npm install
npm run dev
```

Open **http://localhost:5173**. The Vite dev server proxies `/api` requests to the backend.

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/health` | Health check — `{"status":"ok"}` |
| `GET`  | `/api/posts?author=&q=` | Latest 50 posts (newest first). Optional `author` and keyword `q` filters. |
| `POST` | `/api/posts` | Create a post. Body: `{"author":"…","content":"…"}` (max 280 chars). |

## Frontend features

- **Deck layout** — three horizontally scrollable columns:
  - **All** — every post
  - **Mine** — filtered by author (from a local input)
  - **Search** — keyword search via the `q` param
- **Compose box** — author + content with a 280-character counter
- **Polling** — each column refreshes every 5 seconds

## Configuration

`backend/src/main/resources/application.yml`:

```yaml
spring:
  datasource:
    url: jdbc:sqlite:${DB_PATH:/data/app.db}?journal_mode=WAL
  jpa:
    properties:
      hibernate:
        dialect: org.hibernate.community.dialect.SQLiteDialect
    hibernate:
      ddl-auto: update

server:
  port: 8080
```

Set `DB_PATH` to control where the SQLite file is stored. For local development:

```bash
DB_PATH=../data/app.db mvn spring-boot:run
```

## Production build

```bash
docker build -t obechow:dev .
docker run --rm -p 8080:8080 \
  -v "$PWD/data:/data" \
  -e DB_PATH=/data/app.db \
  obechow:dev
```

Open **http://localhost:8080**. The multi-stage build compiles the frontend into the Spring Boot JAR under `classpath:/static`; the final image contains only the JRE and application JAR. Non-API GET routes without a file extension forward to `index.html` for SPA routing.

## Delivery workflow

Pull requests build the production image without registry or SSH credentials.
A push to `main` publishes both `latest` and an immutable full-commit-SHA tag to
`ghcr.io/fallrising/obechow`. VPS deployment is disabled by default and runs
only when the repository variable `DEPLOY_ENABLED` is exactly `true`.

See the CI/CD runbook for the required SSH secrets and activation sequence.

The reviewed VPS bundle lives in `ops/`. It deploys only a full lowercase
40-character Git SHA, waits for the container health check, keeps SQLite in a
bind mount, and never prunes unrelated host resources. Validate it locally
before installation:

```bash
tests/ops/deployment_bundle_test.sh
```

Repository Phase 5 does not install or mutate a VPS. Keep deployment disabled
until the runbook's operator prerequisites and first manual verification pass.

Phase 6 repository readiness adds a read-only host preflight and an isolated
local Docker rehearsal:

```bash
tests/ops/rollout_preflight_test.sh
tests/ops/rollout_rehearsal_test.sh
```

The host preflight verifies reviewed bundle identity, Docker/Compose
capability, the `edge` network, Traefik resolver `le`, exact DNS, and both
release and rollback full-SHA manifests without deploying. The Docker
rehearsal proves local replacement and SQLite persistence only; neither command
is evidence of a real VPS rollout. Keep `DEPLOY_ENABLED=false` until the
runbook's external gate is complete.

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/TECH_SPEC.md](./docs/TECH_SPEC.md) | Architecture, tech choices, API spec, progress |
| [docs/CI_CD_RUNBOOK.md](./docs/CI_CD_RUNBOOK.md) | Single-VPS deploy: `git push` → GHCR → SSH → Traefik |
| [docs/sdd/README.md](./docs/sdd/README.md) | Specification-driven delivery nodes and verification |
| [docs/sdd/P05-vps-deployment-bundle.md](./docs/sdd/P05-vps-deployment-bundle.md) | Immutable VPS bundle behavior and acceptance contract |
| [docs/sdd/P06-rollout-readiness.md](./docs/sdd/P06-rollout-readiness.md) | Read-only first-rollout preflight and external activation boundary |
| [WORK_LOG.md](./WORK_LOG.md) | Build session history |
