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