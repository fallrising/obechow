#!/usr/bin/env bash
# P06-BDD-05 — Isolated real-Docker replacement rehearsal.
# Builds a local synthetic full-SHA image, starts only `app` on a unique
# external bridge network with an absolute temporary data bind, proves
# hardening + POST persistence across force-recreate, then removes only
# resources this script created. No host ports, registry pull of the app
# image, prune, VPS, DNS, SSH, GitHub, or Traefik.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_DIR="$PROJECT_ROOT/ops"
COMPOSE_FILE="$OPS_DIR/compose.yml"
IMAGE_REPO="ghcr.io/fallrising/obechow"

TEST_TEMP=""
EXIT_CODE=0
IMAGE_BUILT=0
NETWORK_CREATED=0
COMPOSE_UP=0
OPS_DATA_EXISTED=0
SYNTHETIC_TAG=""
IMAGE_REF=""
UNIQUE_SUFFIX=""
COMPOSE_PROJECT=""
NETWORK_NAME=""
DATA_DIR=""
OVERRIDE_FILE=""
ENV_FILE=""
APP_HOST="rehearsal.invalid"
AUTHOR=""
CONTENT=""

compose_cmd() {
  docker compose \
    --project-name "$COMPOSE_PROJECT" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    -f "$OVERRIDE_FILE" \
    "$@"
}

cleanup() {
  local trap_status=$?
  # Never let cleanup failures mask the primary test outcome.
  set +e
  set +u

  if [[ "${COMPOSE_UP}" -eq 1 ]]; then
    # Safe even when no containers were created (partial up / failed health wait).
    compose_cmd down --remove-orphans >/dev/null 2>&1
  fi

  if [[ "${NETWORK_CREATED}" -eq 1 ]]; then
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1
  fi

  if [[ "${IMAGE_BUILT}" -eq 1 ]]; then
    docker image rm -f "$IMAGE_REF" >/dev/null 2>&1
  fi

  if [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" && "$TEST_TEMP" == /tmp/* ]]; then
    rm -rf -- "$TEST_TEMP"
  fi

  if (( EXIT_CODE == 0 && trap_status != 0 )); then
    EXIT_CODE=$trap_status
  fi
  exit "$EXIT_CODE"
}
trap cleanup EXIT

TEST_TEMP="$(mktemp -d)"
if [[ -e "$OPS_DIR/data" ]]; then
  OPS_DATA_EXISTED=1
fi

# Generate unique Docker-safe values with Bash builtins so cleanup is already
# armed before any optional runtime dependency is used.
for _ in {1..10}; do
  printf -v HEX_CHUNK '%04x' "$RANDOM"
  SYNTHETIC_TAG+="$HEX_CHUNK"
done
for _ in {1..4}; do
  printf -v HEX_CHUNK '%04x' "$RANDOM"
  UNIQUE_SUFFIX+="$HEX_CHUNK"
done
if [[ ! "$SYNTHETIC_TAG" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'FAIL  synthetic tag is not 40 lowercase hex: %s\n' "$SYNTHETIC_TAG" >&2
  EXIT_CODE=1
  exit 1
fi

IMAGE_REF="${IMAGE_REPO}:${SYNTHETIC_TAG}"
COMPOSE_PROJECT="p06rehearsal${UNIQUE_SUFFIX}"
NETWORK_NAME="p06edge${UNIQUE_SUFFIX}"
DATA_DIR="$TEST_TEMP/data"
OVERRIDE_FILE="$TEST_TEMP/compose.override.yml"
ENV_FILE="$TEST_TEMP/compose.env"
AUTHOR="rehearsal-${UNIQUE_SUFFIX}"
CONTENT="p06-bdd-05-${UNIQUE_SUFFIX}-persistence-check"

mkdir -p -- "$DATA_DIR"

die() {
  printf 'FAIL  %s\n' "$*" >&2
  EXIT_CODE=1
  exit 1
}

pass() {
  printf 'PASS  %s\n' "$*"
}

step() {
  printf '\n=== %s ===\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

container_id() {
  compose_cmd ps -q app
}

container_ip() {
  local cid="$1"
  docker inspect --type container \
    --format "{{(index .NetworkSettings.Networks \"${NETWORK_NAME}\").IPAddress}}" \
    "$cid"
}

# Shared container hardening/runtime oracle for containers A and B.
assert_container_runtime() {
  local label="$1"
  local cid="$2"
  local inspect_file="$3"

  docker inspect --type container --format '{{json .}}' "$cid" > "$inspect_file"
  python3 - "$inspect_file" "$DATA_DIR" "$IMAGE_REF" "$NETWORK_NAME" "$label" <<'PY'
import json
import os
import sys

inspect_path, data_dir, image_ref, network_name, label = sys.argv[1:6]
data_dir = os.path.realpath(data_dir)

with open(inspect_path, encoding="utf-8") as stream:
    container = json.load(stream)

errors = []


def opt_set(raw: str) -> set[str]:
    return {part.strip() for part in (raw or "").split(",") if part.strip()}


host_config = container.get("HostConfig") or {}
state = container.get("State") or {}
config = container.get("Config") or {}
network_settings = container.get("NetworkSettings") or {}

if host_config.get("ReadonlyRootfs") is not True:
    errors.append(f"{label}: ReadonlyRootfs is not true")

security_opt = host_config.get("SecurityOpt") or []
if "no-new-privileges:true" not in security_opt and "no-new-privileges=true" not in security_opt:
    errors.append(f"{label}: SecurityOpt missing no-new-privileges: got {security_opt!r}")

port_bindings = host_config.get("PortBindings")
if port_bindings not in (None, {}, []):
    errors.append(f"{label}: HostConfig.PortBindings is not empty: {port_bindings!r}")

networks = network_settings.get("Networks") or {}
network_keys = sorted(networks.keys())
if network_keys != [network_name]:
    errors.append(
        f"{label}: attached networks {network_keys!r} != exact [{network_name!r}]"
    )

tmpfs = host_config.get("Tmpfs") or {}
tmp_opts = opt_set(tmpfs.get("/tmp", ""))
sqlite_opts = opt_set(tmpfs.get("/sqlite-tmp", ""))
tmp_required = {"rw", "noexec", "nosuid", "nodev", "size=64m"}
sqlite_required = {"rw", "exec", "nosuid", "nodev", "size=16m"}
if not tmp_required.issubset(tmp_opts):
    errors.append(
        f"{label}: /tmp tmpfs missing required opts; have {sorted(tmp_opts)!r} need {sorted(tmp_required)!r}"
    )
if not sqlite_required.issubset(sqlite_opts):
    errors.append(
        f"{label}: /sqlite-tmp tmpfs missing required opts; have {sorted(sqlite_opts)!r} need {sorted(sqlite_required)!r}"
    )
if "noexec" in sqlite_opts:
    errors.append(f"{label}: /sqlite-tmp must not include noexec: {sorted(sqlite_opts)!r}")
if "exec" in tmp_opts and "noexec" not in tmp_opts:
    errors.append(f"{label}: /tmp must not be executable: {sorted(tmp_opts)!r}")

data_bind = None
for mount in container.get("Mounts") or []:
    if mount.get("Destination") == "/data":
        data_bind = mount
        break
if data_bind is None:
    errors.append(f"{label}: missing /data mount")
else:
    if data_bind.get("Type") != "bind":
        errors.append(f"{label}: /data Type is not bind: {data_bind.get('Type')!r}")
    if data_bind.get("RW") is not True:
        errors.append(f"{label}: /data RW is not true: {data_bind.get('RW')!r}")
    source = data_bind.get("Source") or ""
    if os.path.realpath(source) != data_dir and source != data_dir:
        errors.append(
            f"{label}: /data Source {source!r} is not exact temporary bind {data_dir!r}"
        )

config_image = config.get("Image")
if config_image != image_ref:
    errors.append(f"{label}: Config.Image {config_image!r} != {image_ref!r}")

health = (state.get("Health") or {}).get("Status")
if health != "healthy":
    errors.append(f"{label}: Health.Status {health!r} != 'healthy'")

if errors:
    print(f"{label} runtime inspection failures:", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print(f"{label}: ReadonlyRootfs=true")
print(f"{label}: no-new-privileges present")
print(f"{label}: PortBindings empty")
print(f"{label}: networks=[{network_name}]")
print(f"{label}: /tmp tmpfs={tmpfs.get('/tmp')}")
print(f"{label}: /sqlite-tmp tmpfs={tmpfs.get('/sqlite-tmp')}")
print(f"{label}: /data Source={data_bind.get('Source')} RW={data_bind.get('RW')}")
print(f"{label}: image={config_image}")
print(f"{label}: health={health}")
PY
}

wait_http() {
  local ip="$1"
  local path="$2"
  local attempts=30
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --connect-timeout 2 --max-time 5 \
      "http://${ip}:8080${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Read-only residual queries used after explicit cleanup and for evidence.
residual_project_containers() {
  docker ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}"
}

residual_image_ids() {
  # Exact repository:tag only; empty when the synthetic tag is gone.
  docker image ls -q --no-trunc --filter "reference=${IMAGE_REF}"
}

require_cmd docker
require_cmd curl
require_cmd python3
docker info >/dev/null 2>&1 || die "Docker Engine is not available"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is not available"
[[ -f "$COMPOSE_FILE" ]] || die "missing compose file: $COMPOSE_FILE"
[[ -f "$PROJECT_ROOT/Dockerfile" ]] || die "missing Dockerfile at repository root"

step "1. Unique resources and Compose override"
printf 'project=%s\nnetwork=%s\nimage=%s\ndata=%s\n' \
  "$COMPOSE_PROJECT" "$NETWORK_NAME" "$IMAGE_REF" "$DATA_DIR"

printf 'APP_HOST=%s\nTAG=%s\n' "$APP_HOST" "$SYNTHETIC_TAG" > "$ENV_FILE"

# Absolute temporary data bind; unique external network; never pull the app image.
cat > "$OVERRIDE_FILE" <<EOF
services:
  app:
    pull_policy: never
    volumes:
      - type: bind
        source: ${DATA_DIR}
        target: /data
    networks:
      - edge

networks:
  edge:
    name: ${NETWORK_NAME}
    external: true
EOF

pass "unique project, network name, synthetic 40-hex tag, and override prepared"

step "2. Create exact bridge network"
docker network create --driver bridge "$NETWORK_NAME" >/dev/null
NETWORK_CREATED=1
pass "created network ${NETWORK_NAME}"

step "3. Build root production image under synthetic full-SHA tag"
docker build -t "$IMAGE_REF" "$PROJECT_ROOT"
IMAGE_BUILT=1
pass "built ${IMAGE_REF}"

step "4. Start only app with health wait (no host ports)"
# Mark for cleanup BEFORE up so a partial create or failed health wait cannot leak.
COMPOSE_UP=1
compose_cmd up -d --no-deps --wait --wait-timeout 120 app
pass "compose up --wait for service app succeeded"

CID_A="$(container_id)"
[[ -n "$CID_A" ]] || die "container id for app is empty after up"
IP_A="$(container_ip "$CID_A")"
[[ -n "$IP_A" ]] || die "container IP on ${NETWORK_NAME} is empty"
pass "app container A id=${CID_A} ip=${IP_A}"

step "5. Inspect container A hardening, bind, network, ports, image, and health"
assert_container_runtime "A" "$CID_A" "$TEST_TEMP/inspect-a.json"
pass "container A: read-only root, no-new-privileges, empty PortBindings, unique network only, /data RW bind, full tmpfs contract, image, health"

step "6. POST uniquely identified post and assert response fields"
wait_http "$IP_A" "/api/health" || die "HTTP /api/health not reachable on container A"

POST_BODY="$(curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"author\":\"${AUTHOR}\",\"content\":\"${CONTENT}\"}" \
  "http://${IP_A}:8080/api/posts")"

printf 'POST response: %s\n' "$POST_BODY"

POST_META="$(POST_BODY="$POST_BODY" AUTHOR="$AUTHOR" CONTENT="$CONTENT" python3 <<'PY'
import json
import os
import sys

post = json.loads(os.environ["POST_BODY"])
author = os.environ["AUTHOR"]
content = os.environ["CONTENT"]
errors = []

if not isinstance(post, dict):
    errors.append(f"response is not an object: {type(post).__name__}")
else:
    if post.get("author") != author:
        errors.append(f"author {post.get('author')!r} != {author!r}")
    if post.get("content") != content:
        errors.append(f"content {post.get('content')!r} != {content!r}")
    if not isinstance(post.get("id"), int):
        errors.append(f"id is not int: {post.get('id')!r}")
    if not isinstance(post.get("createdAt"), str) or not post.get("createdAt"):
        errors.append(f"createdAt missing or not string: {post.get('createdAt')!r}")
    expected_keys = {"id", "author", "content", "createdAt"}
    actual_keys = set(post.keys())
    if actual_keys != expected_keys:
        errors.append(f"keys {sorted(actual_keys)!r} != {sorted(expected_keys)!r}")

if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)

print(f"{post['id']}\t{post['createdAt']}")
PY
)" || die "POST response field assertion failed"

POST_ID="${POST_META%%$'\t'*}"
POST_CREATED_AT="${POST_META#*$'\t'}"
[[ -n "$POST_ID" && -n "$POST_CREATED_AT" ]] || die "failed to capture post id/createdAt"
pass "POST created id=${POST_ID} author=${AUTHOR} with exact response fields"

step "7. Force-recreate only app and prove new healthy container"
compose_cmd up -d --no-deps --force-recreate --wait --wait-timeout 120 app

CID_B="$(container_id)"
[[ -n "$CID_B" ]] || die "container id for app is empty after force-recreate"
[[ "$CID_B" != "$CID_A" ]] || die "container id did not change after force-recreate (still ${CID_A})"

HEALTH_B="$(docker inspect --type container \
  --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  "$CID_B")"
[[ "$HEALTH_B" == "healthy" ]] || die "container B health is ${HEALTH_B}, expected healthy"

assert_container_runtime "B" "$CID_B" "$TEST_TEMP/inspect-b.json"

IP_B="$(container_ip "$CID_B")"
[[ -n "$IP_B" ]] || die "container B IP is empty"
wait_http "$IP_B" "/api/health" || die "HTTP /api/health not reachable on container B"
pass "force-recreate changed id ${CID_A} -> ${CID_B} and remains healthy with full hardening"

step "8. GET proves exact post persisted across replacement"
GET_BODY="$(curl -fsS "http://${IP_B}:8080/api/posts?author=${AUTHOR}")"
printf 'GET response: %s\n' "$GET_BODY"

GET_BODY="$GET_BODY" POST_ID="$POST_ID" AUTHOR="$AUTHOR" CONTENT="$CONTENT" \
  POST_CREATED_AT="$POST_CREATED_AT" python3 <<'PY' || die "GET persistence assertion failed"
import json
import os
import sys

posts = json.loads(os.environ["GET_BODY"])
post_id = int(os.environ["POST_ID"])
author = os.environ["AUTHOR"]
content = os.environ["CONTENT"]
created_at = os.environ["POST_CREATED_AT"]

if not isinstance(posts, list):
    print(f"GET body is not a list: {type(posts).__name__}", file=sys.stderr)
    sys.exit(1)

match = None
for post in posts:
    if post.get("id") == post_id:
        match = post
        break

if match is None:
    print(f"post id={post_id} not found in GET response: {posts!r}", file=sys.stderr)
    sys.exit(1)

errors = []
if match.get("author") != author:
    errors.append(f"author {match.get('author')!r} != {author!r}")
if match.get("content") != content:
    errors.append(f"content {match.get('content')!r} != {content!r}")
# Instant may round-trip through SQLite with reduced fractional precision;
# require a non-empty createdAt that shares the POST second prefix.
got_created = match.get("createdAt")
if not isinstance(got_created, str) or not got_created:
    errors.append(f"createdAt missing after recreate: {got_created!r}")
elif len(created_at) >= 19 and not got_created.startswith(created_at[:19]):
    errors.append(
        f"createdAt second prefix {got_created!r} does not match POST {created_at!r}"
    )
if errors:
    for err in errors:
        print(err, file=sys.stderr)
    sys.exit(1)

print(f"persisted id={post_id} author={author} content={content} createdAt={got_created}")
PY
pass "exact post id=${POST_ID} author/content persisted after replacement"

step "9. Prove SQLite files live only under temporary bind"
[[ -f "$DATA_DIR/app.db" ]] || die "missing ${DATA_DIR}/app.db"
[[ -s "$DATA_DIR/app.db" ]] || die "${DATA_DIR}/app.db is empty"
printf 'temporary bind contents:\n'
ls -la -- "$DATA_DIR"

# WAL files are expected under SQLite WAL mode but app.db is the required proof.
SQLITE_COUNT="$(find "$DATA_DIR" -maxdepth 1 -type f \( -name 'app.db' -o -name 'app.db-*' \) | wc -l)"
[[ "$SQLITE_COUNT" -ge 1 ]] || die "no SQLite files under temporary bind"
pass "SQLite files present under temporary bind (count=${SQLITE_COUNT})"

if [[ "$OPS_DATA_EXISTED" -eq 0 && -e "$OPS_DIR/data" ]]; then
  die "rehearsal created ops/data; absolute temporary bind was not isolated"
fi
pass "no ops/data or repo runtime path created by rehearsal"

step "10. Cleanup evidence with residual-resource verification"
printf 'Will remove: compose project=%s network=%s image=%s temp=%s\n' \
  "$COMPOSE_PROJECT" "$NETWORK_NAME" "$IMAGE_REF" "$TEST_TEMP"

# --- Compose project ---
compose_cmd down --remove-orphans
printf 'residual query: docker ps -aq --filter label=com.docker.compose.project=%s\n' \
  "$COMPOSE_PROJECT"
PROJECT_LEFTOVERS="$(residual_project_containers || true)"
printf 'residual project containers: %s\n' "${PROJECT_LEFTOVERS:-<none>}"
if [[ -n "${PROJECT_LEFTOVERS}" ]]; then
  # Keep COMPOSE_UP=1 so EXIT trap retries exact compose down.
  die "cleanup verification failed: containers remain for compose project ${COMPOSE_PROJECT}: ${PROJECT_LEFTOVERS}"
fi
COMPOSE_UP=0
printf 'compose project removed and verified absent: %s\n' "$COMPOSE_PROJECT"

# --- Exact network ---
docker network rm "$NETWORK_NAME"
printf 'residual query: docker network inspect %s\n' "$NETWORK_NAME"
# Exact-name inspect is the authoritative read-only proof of absence.
if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  die "cleanup verification failed: docker network inspect still resolves ${NETWORK_NAME}"
fi
NETWORK_CREATED=0
printf 'network removed and verified absent: %s\n' "$NETWORK_NAME"

# --- Exact image tag ---
docker image rm -f "$IMAGE_REF" >/dev/null
printf 'residual query: docker image ls -q --filter reference=%s\n' "$IMAGE_REF"
IMAGE_LEFTOVERS="$(residual_image_ids || true)"
printf 'residual image ids: %s\n' "${IMAGE_LEFTOVERS:-<none>}"
if [[ -n "${IMAGE_LEFTOVERS}" ]]; then
  # Keep IMAGE_BUILT=1 so EXIT trap retries exact image rm.
  die "cleanup verification failed: image tag still exists: ${IMAGE_REF} ids=${IMAGE_LEFTOVERS}"
fi
if docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  die "cleanup verification failed: docker image inspect still resolves ${IMAGE_REF}"
fi
IMAGE_BUILT=0
printf 'image removed and verified absent: %s\n' "$IMAGE_REF"

# --- Guarded temp directory ---
if [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" && "$TEST_TEMP" == /tmp/* ]]; then
  rm -rf -- "$TEST_TEMP"
  printf 'temp directory removed: %s\n' "$TEST_TEMP"
  TEST_TEMP=""
fi

pass "exact compose project, network, image tag, and temp directory cleaned and verified"

printf '\n=== Result ===\n'
printf 'P06-BDD-05 isolated Docker rehearsal passed\n'
printf 'synthetic_tag=%s\n' "$SYNTHETIC_TAG"
printf 'compose_project=%s\n' "$COMPOSE_PROJECT"
printf 'network=%s\n' "$NETWORK_NAME"
printf 'post_id=%s\n' "$POST_ID"
EXIT_CODE=0
