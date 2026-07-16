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
├── backend/    # Spring Boot REST API
├── frontend/   # Vite + React SPA
└── data/       # SQLite database (created at runtime, gitignored)
```

## Prerequisites

- Java 17+
- Maven 3.9+
- Node.js 18+

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
cd frontend && npm run build    # output: frontend/dist
cd ../backend && mvn package
```

The backend serves static files from `frontend/dist` and forwards non-API GET routes to `index.html` (SPA fallback).

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/TECH_SPEC.md](./docs/TECH_SPEC.md) | Architecture, tech choices, API spec, progress |
| [docs/CI_CD_RUNBOOK.md](./docs/CI_CD_RUNBOOK.md) | Single-VPS deploy: `git push` → GHCR → SSH → Traefik |
| [WORK_LOG.md](./WORK_LOG.md) | Build session history |