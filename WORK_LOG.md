# Work Log — Obechow (Skan)

**Date:** 2026-07-13  
**Repository:** `git@github.com:fallrising/obechow.git`  
**Author:** Grok CLI session

---

## Summary

Built a minimal Twitter deck clone ("Skan") as a full-stack monorepo, verified it locally, pushed it to GitHub, then cleaned up runtime artifacts and documented the work.

---

## 1. Project scaffold

Created the `skan/` directory with two sub-projects:

### Backend (`backend/`)

- **Spring Boot 3.3.5** on **Java 17** with Maven
- Dependencies:
  - `spring-boot-starter-web`
  - `spring-boot-starter-data-jpa`
  - `org.xerial:sqlite-jdbc`
  - `org.hibernate.orm:hibernate-community-dialects` (version from Boot parent)
- **`application.yml`** configured with SQLite WAL mode, `SQLiteDialect`, `ddl-auto: update`, port 8080
- **`Post` entity** — `id`, `author`, `content` (max 280), `createdAt`
- **REST API:**
  - `GET /api/health` → `{"status":"ok"}`
  - `GET /api/posts?author=&q=` → latest 50 posts, optional filters
  - `POST /api/posts` → create post (201)
- **SPA fallback** — `SpaFallbackFilter` forwards non-`/api` GET paths without file extensions to `/index.html`
- **Static serving** — `WebConfig` serves `frontend/dist`

### Frontend (`frontend/`)

- Scaffolded with `npm create vite@latest -- --template react-ts`
- Added **Tailwind CSS v4** (`@tailwindcss/vite`), **shadcn/ui** components (Card, Button, Input, Textarea)
- **Deck UI** — horizontally scrollable columns: All, Mine, Search
- **Compose box** — author + content with 280-char counter, posts to `/api/posts`
- **Polling** — each column fetches `GET /api/posts` every 5 seconds
- **`vite.config.ts`** — dev proxy `/api` → `http://localhost:8080`, build output `dist/`

---

## 2. Local verification

Because system Java/Maven were not installed, a portable **JDK 17** (Temurin) and **Maven 3.9.9** were downloaded to `.tools/` and `/tmp/` for testing only.

Verified:

| Check | Result |
|-------|--------|
| `mvn spring-boot:run` with `DB_PATH=…/data/app.db` | Started on port 8080 |
| `GET /api/health` | `{"status":"ok"}` |
| `POST /api/posts` | Created post, persisted to SQLite |
| `GET /api/posts?author=alice` | Returned filtered posts |
| `npm run dev` | Started on port 5173 |
| Vite `/api` proxy | Forwarded to backend correctly |
| SPA fallback `GET /deck` | Returned `index.html` (200) |
| SQLite WAL files | `app.db`, `app.db-wal`, `app.db-shm` created in `data/` |

---

## 3. GitHub deployment

Initialized git in `skan/`, added root `.gitignore`, committed 38 source files, and pushed to:

```
git@github.com:fallrising/obechow.git  (branch: main)
```

**Excluded from git:** `data/`, `.tools/`, `backend/target/`, `frontend/node_modules/`, `frontend/dist/`

**Commit:** `b0564a6` — *Initial commit: Skan Twitter deck clone*

---

## 4. Cleanup (this session)

Stopped background processes started during verification:

- Spring Boot (`mvn spring-boot:run`) — PID 2655726 / 2655796
- Vite dev server (`npm run dev`) — PID 2655885 / 2655886

Removed local runtime artifacts:

- `.tools/` — portable JDK used for testing
- `data/` — SQLite database and WAL files
- `backend/target/` — Maven build output
- `frontend/node_modules/` — npm dependencies
- `frontend/dist/` — production build output

Added project documentation:

- `README.md` — setup, API reference, configuration
- `WORK_LOG.md` — this file

---

## 5. How to resume development

```bash
git clone git@github.com:fallrising/obechow.git
cd obechow

# Terminal 1
cd backend && DB_PATH=../data/app.db mvn spring-boot:run

# Terminal 2
cd frontend && npm install && npm run dev
```

Open http://localhost:5173, enter an author name, compose a post, and confirm it appears in all three deck columns.

---

## 2026-07-16 — Phase 3 production image

Implemented the next deployment milestone:

- Added a multi-stage `Dockerfile` using Node 22, Maven with Temurin 17, and a JRE-only runtime image.
- Added `.dockerignore` rules for source-control metadata, local dependencies, build output, and runtime data.
- Bundled the Vite output into the Spring Boot JAR at `classpath:/static`.
- Removed the filesystem-only `WebConfig` resource override so packaged static assets use Spring Boot's default handler.
- Corrected the documented Node.js prerequisite to match Vite 8's engine requirement.

Verified the `obechow:dev` image locally:

| Check | Result |
|-------|--------|
| Multi-stage `docker build` | Passed |
| `GET /api/health` | `{"status":"ok"}` |
| `GET /` and `GET /deck` | Bundled `index.html` returned |
| Hashed JavaScript asset | Served from the packaged JAR |
| `POST /api/posts` + filtered `GET` | SQLite write/read round trip passed |

---

## 2026-07-29 — Phase 4 CI/CD workflow

Established a lightweight SDD package before implementation:

- froze pull-request, GHCR tagging, deploy gating, SSH trust, concurrency, and
  permission contracts in `docs/sdd/P04-ci-cd.md`;
- split implementation into delegated P04-T01 and main-agent P04-T02 review;
- committed and pushed the specification before production workflow code.

OpenCode implemented the first `.github/workflows/deploy.yml` draft within its
single-file ownership boundary. Main-agent review rejected the draft unchanged
because pull-request builds inherited `packages: write` and the runtime
`drone-ssh` binary was not explicitly pinned. The adopted workflow:

- separates credential-free pull-request validation from main-only publication;
- publishes `latest` plus the immutable full Git SHA;
- pins every action reference to a full commit SHA;
- verifies the VPS host fingerprint and pins `drone-ssh` 1.8.2;
- keeps deployment disabled unless `DEPLOY_ENABLED` is exactly `true`;
- serializes production deploy jobs without cancelling an active deployment.

Local evidence:

| Check | Result |
|---|---|
| `actionlint .github/workflows/deploy.yml` | Passed |
| Workflow contract assertions | Passed; seven action references pinned |
| `docker build -t obechow:p04-verification .` | Passed |
| `git diff --check` | Passed |

Online evidence:

| Check | Result |
|---|---|
| PR run `30468132339` | `validate` success; `publish` and `deploy` skipped |
| PR #1 squash merge | `2037ba806789f2cc3f1f9259194b740872b826f2` |
| Main run `30469807025` | `publish` success; `validate` and `deploy` skipped |
| GHCR tags | `latest` and full merge SHA point to digest `sha256:4949f2…e1174` |

Phase 4 is complete. VPS provisioning, deploy secrets, and an enabled live
deployment remain Phase 5/6 work.

---

## 2026-07-29 — Phase 5 versioned VPS deployment bundle

Froze a second SDD node before implementation:

- restricted production releases to `twitter-deck` plus an immutable full Git
  SHA;
- defined Compose preflight, service-scoped pull/recreate, bounded health wait,
  persistent SQLite, Traefik-only ingress, and failure behavior;
- excluded VPS mutation, credentials, live activation, global Docker cleanup,
  zero downtime, and automated rollback.

OpenCode implemented P05-T01 and P05-T02 inside their task path boundaries.
Main-agent review rejected both drafts unchanged. Production-bundle corrections
fixed the Traefik `Host()` matcher, prevented `.env` from overriding the image
repository, aligned the `le` resolver, and removed `container_name`. Test
corrections added an executable bit, exact Compose JSON assertions, required
variable failures, a shell-like input case, and failure-stop command oracles.

The accepted deployment contract test has 42 passing assertions and runs before
the image build in both pull-request validation and `main` publication jobs.
`actionlint` and whitespace checks pass.

The first read-only image smoke exposed a real runtime issue: Docker mounted
plain `/tmp` with `noexec`, while Xerial SQLite JDBC extracts and loads a native
library from its temp directory. The corrected Compose model keeps general
`/tmp` at `noexec` and provides only `/sqlite-tmp` as a bounded executable
tmpfs through `-Dorg.sqlite.tmpdir=/sqlite-tmp`.

Local runtime evidence after the correction:

| Check | Result |
|---|---|
| Production image build | Passed; `sha256:a30e0777…b3f62b` |
| Health under read-only root | Passed |
| General `/tmp` | `noexec`, 64 MiB |
| SQLite `/sqlite-tmp` | `exec`, 16 MiB |
| POST then GET | Passed |
| Container A → B replacement | id=1 post persisted in bind-mounted SQLite |

Both named smoke containers and their temporary data directory were removed.
The local verification image tag remains available. Actual VPS installation,
DNS/Traefik checks, repository secrets, and `DEPLOY_ENABLED=true` remain Phase
6 operator gates.
