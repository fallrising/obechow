#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_DIR="$PROJECT_ROOT/ops"
TEST_TEMP="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  if [[ -n "${TEST_TEMP:-}" && -d "$TEST_TEMP" && "$TEST_TEMP" == /tmp/* ]]; then
    rm -rf -- "$TEST_TEMP"
  fi
}
trap cleanup EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$*"
}

make_fake_docker() {
  local bindir="$TEST_TEMP/fake-bin"
  mkdir -p "$bindir"
  cat > "$bindir/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
case "${FAKE_DOCKER_FAIL:-none}" in
  config) [[ "$*" == *"config"* ]] && exit 41 ;;
  pull) [[ "$*" == *"pull"* ]] && exit 42 ;;
  up) [[ "$*" == *" up "* ]] && exit 43 ;;
esac
exit 0
SCRIPT
  chmod +x "$bindir/docker"
  printf '%s\n' "$bindir"
}

mock_app_dir() {
  local app_dir="$TEST_TEMP/apps/twitter-deck"
  mkdir -p "$app_dir"
  printf '%s\n' "$app_dir"
}

assert_log() {
  local label="$1"
  local logfile="$2"
  shift 2
  local -a actual=()
  mapfile -t actual < "$logfile"
  local -a expected=("$@")

  if [[ "${actual[*]}" == "${expected[*]}" && "${#actual[@]}" -eq "${#expected[@]}" ]]; then
    pass "$label"
  else
    fail "$label: expected [${expected[*]}], got [${actual[*]}]"
  fi
}

printf '=== 1. Syntax checks ===\n'
bash -n "$0" && pass "test script syntax" || fail "test script syntax"
bash -n "$OPS_DIR/deploy.sh" && pass "deploy script syntax" || fail "deploy script syntax"

printf '=== 2. Compose model contract ===\n'
compose_model_test() {
  local env_file="$TEST_TEMP/compose.env"
  local model_file="$TEST_TEMP/compose.json"
  local error_file="$TEST_TEMP/compose.err"
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  printf 'APP_HOST=app.test.com\nTAG=%s\n' "$sha" > "$env_file"
  if docker compose --env-file "$env_file" -f "$OPS_DIR/compose.yml" \
    config --format json > "$model_file" 2> "$error_file"; then
    pass "compose config resolves"
  else
    fail "compose config resolves: $(< "$error_file")"
    return
  fi

  if python3 - "$model_file" "$OPS_DIR/data" "$sha" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    model = json.load(stream)

service = model["services"]["app"]
labels = service["labels"]
volumes = service.get("volumes", [])
expected_data = os.path.realpath(sys.argv[2])
expected_sha = sys.argv[3]

assert service["image"] == f"ghcr.io/fallrising/obechow:{expected_sha}"
assert not service.get("ports")
assert service["environment"]["DB_PATH"] == "/data/app.db"
assert any(
    volume.get("type") == "bind"
    and os.path.realpath(volume.get("source", "")) == expected_data
    and volume.get("target") == "/data"
    for volume in volumes
)
assert service["networks"] == {"edge": None}
assert model["networks"]["edge"]["external"] is True
assert model["networks"]["edge"]["name"] == "edge"
assert labels["traefik.enable"] == "true"
assert labels["traefik.docker.network"] == "edge"
assert labels["traefik.http.routers.twitter-deck.rule"] == "Host(`app.test.com`)"
assert labels["traefik.http.routers.twitter-deck.entrypoints"] == "websecure"
assert labels["traefik.http.routers.twitter-deck.tls"] == "true"
assert labels["traefik.http.routers.twitter-deck.tls.certresolver"] == "le"
assert labels["traefik.http.services.twitter-deck.loadbalancer.server.port"] == "8080"
assert service["read_only"] is True
assert "no-new-privileges:true" in service["security_opt"]
assert "/tmp" in service["tmpfs"]
assert service["logging"] == {
    "driver": "json-file",
    "options": {"max-file": "3", "max-size": "10m"},
}
assert service["healthcheck"]["test"] == [
    "CMD-SHELL",
    "wget -qO- http://127.0.0.1:8080/api/health >/dev/null || exit 1",
]
PY
  then
    pass "resolved model matches persistence, ingress, health, and hardening contract"
  else
    fail "resolved model matches persistence, ingress, health, and hardening contract"
  fi

  printf 'TAG=%s\n' "$sha" > "$env_file"
  if env -u APP_HOST -u TAG docker compose --env-file "$env_file" \
    -f "$OPS_DIR/compose.yml" config --quiet > /dev/null 2>&1; then
    fail "APP_HOST is required"
  else
    pass "APP_HOST is required"
  fi

  printf 'APP_HOST=app.test.com\n' > "$env_file"
  if env -u APP_HOST -u TAG docker compose --env-file "$env_file" \
    -f "$OPS_DIR/compose.yml" config --quiet > /dev/null 2>&1; then
    fail "TAG is required"
  else
    pass "TAG is required"
  fi
}
compose_model_test

printf '=== 3. Valid deployment sequence ===\n'
valid_deploy_test() {
  local app_dir
  local bindir
  local logfile="$TEST_TEMP/valid.log"
  local output="$TEST_TEMP/valid.out"
  local rc=0
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  app_dir="$(mock_app_dir)"
  bindir="$(make_fake_docker)"
  : > "$logfile"

  PATH="$bindir:$PATH" \
    FAKE_DOCKER_LOG="$logfile" \
    OBECHOW_DEPLOY_ROOT="$(dirname "$app_dir")" \
    bash "$OPS_DIR/deploy.sh" twitter-deck "$sha" > "$output" 2>&1 || rc=$?

  [[ "$rc" -eq 0 ]] && pass "valid request exits zero" || fail "valid request exits zero: got $rc"
  assert_log "valid request has exact command sequence" "$logfile" \
    "compose config --quiet" \
    "compose pull app" \
    "compose up -d --no-deps --force-recreate --wait --wait-timeout 120 app"

  local expected="Deployed twitter-deck at ghcr.io/fallrising/obechow:$sha"
  grep -qFx "$expected" "$output" \
    && pass "success reports exact immutable image" \
    || fail "success reports exact immutable image"
}
valid_deploy_test

printf '=== 4. Invalid input isolation ===\n'
invalid_input_test() {
  local app_dir
  local bindir
  local logfile="$TEST_TEMP/invalid.log"
  local output="$TEST_TEMP/invalid.out"
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  app_dir="$(mock_app_dir)"
  bindir="$(make_fake_docker)"

  run_case() {
    local label="$1"
    shift
    local rc=0
    : > "$logfile"
    PATH="$bindir:$PATH" \
      FAKE_DOCKER_LOG="$logfile" \
      OBECHOW_DEPLOY_ROOT="$(dirname "$app_dir")" \
      bash "$OPS_DIR/deploy.sh" "$@" > "$output" 2>&1 || rc=$?

    [[ "$rc" -ne 0 ]] && pass "$label exits non-zero" || fail "$label exits non-zero"
    [[ ! -s "$logfile" ]] && pass "$label invokes no Docker" || fail "$label invokes no Docker"
  }

  run_case "zero arguments"
  run_case "one argument" twitter-deck
  run_case "three arguments" twitter-deck "$sha" extra
  run_case "unknown app" other-app "$sha"
  run_case "empty SHA" twitter-deck ""
  run_case "uppercase SHA" twitter-deck ABCDEF0123456789ABCDEF0123456789ABCDEF01
  run_case "short SHA" twitter-deck abc123
  run_case "non-hex SHA" twitter-deck zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
  run_case "mutable tag" twitter-deck latest
  run_case "shell-like SHA" twitter-deck 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;touch'

  local rc=0
  : > "$logfile"
  PATH="$bindir:$PATH" \
    FAKE_DOCKER_LOG="$logfile" \
    OBECHOW_DEPLOY_ROOT="$TEST_TEMP/does-not-exist" \
    bash "$OPS_DIR/deploy.sh" twitter-deck "$sha" > "$output" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] && pass "missing app directory exits non-zero" || fail "missing app directory exits non-zero"
  [[ ! -s "$logfile" ]] && pass "missing app directory invokes no Docker" || fail "missing app directory invokes no Docker"
}
invalid_input_test

printf '=== 5. Failure propagation ===\n'
failure_injection_test() {
  local app_dir
  local bindir
  local output="$TEST_TEMP/failure.out"
  local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  app_dir="$(mock_app_dir)"
  bindir="$(make_fake_docker)"

  run_failure() {
    local mode="$1"
    shift
    local logfile="$TEST_TEMP/failure-$mode.log"
    local rc=0
    : > "$logfile"

    PATH="$bindir:$PATH" \
      FAKE_DOCKER_LOG="$logfile" \
      FAKE_DOCKER_FAIL="$mode" \
      OBECHOW_DEPLOY_ROOT="$(dirname "$app_dir")" \
      bash "$OPS_DIR/deploy.sh" twitter-deck "$sha" > "$output" 2>&1 || rc=$?

    [[ "$rc" -ne 0 ]] && pass "$mode failure propagates" || fail "$mode failure propagates"
    ! grep -q '^Deployed ' "$output" \
      && pass "$mode failure omits success" \
      || fail "$mode failure omits success"
    assert_log "$mode failure stops command sequence" "$logfile" "$@"
  }

  run_failure config "compose config --quiet"
  run_failure pull "compose config --quiet" "compose pull app"
  run_failure up \
    "compose config --quiet" \
    "compose pull app" \
    "compose up -d --no-deps --force-recreate --wait --wait-timeout 120 app"
}
failure_injection_test

printf '=== 6. Bounded production scope ===\n'
static_contract_test() {
  local deploy_script="$OPS_DIR/deploy.sh"

  if grep -Eq \
    'docker (image )?prune|docker (volume|network) (rm|prune|create)|docker compose (down|rm|kill)' \
    "$deploy_script"; then
    fail "deploy script excludes destructive or global Docker commands"
  else
    pass "deploy script excludes destructive or global Docker commands"
  fi

  if grep -Eq '(^|[[:space:]])eval([[:space:]]|$)' "$deploy_script"; then
    fail "deploy script excludes eval"
  else
    pass "deploy script excludes eval"
  fi
}
static_contract_test

printf '\n=== Result ===\n'
printf 'Passed: %d\nFailed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
exit $((FAIL_COUNT > 0 ? 1 : 0))
