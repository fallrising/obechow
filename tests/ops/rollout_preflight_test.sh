#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_DIR="$PROJECT_ROOT/ops"
PREFLIGHT="$OPS_DIR/rollout-preflight.sh"
TEST_TEMP="$(mktemp -d)"
PASS_COUNT=0
FAIL_COUNT=0

RELEASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
ROLLBACK_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
APP_HOST="app.example.test"
EXPECTED_DNS_IPV4="203.0.113.10"
TRAEFIK_CONTAINER="traefik"
IMAGE_REPO="ghcr.io/fallrising/obechow"
FAKE_SERVER_VERSION="27.5.1"
FAKE_COMPOSE_VERSION="2.29.0"
FAKE_EDGE_NETWORK_ID="net-edge-0123456789abcdef"

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

assert_log_exact() {
  local label="$1"
  local logfile="$2"
  shift 2
  local -a actual=() expected=("$@")
  mapfile -t actual < "$logfile"
  local i match=1
  if [[ "${#actual[@]}" -ne "${#expected[@]}" ]]; then
    match=0
  else
    for ((i = 0; i < ${#expected[@]}; i++)); do
      if [[ "${actual[i]}" != "${expected[i]}" ]]; then
        match=0
        break
      fi
    done
  fi
  if [[ "$match" -eq 1 ]]; then
    pass "$label"
  else
    fail "$label: expected [${#expected[@]}]=[${expected[*]}] got [${#actual[@]}]=[${actual[*]}]"
  fi
}

# Exact stop: command log must equal the given prefix (no later commands).
assert_log_prefix() {
  local label="$1"
  local logfile="$2"
  shift 2
  assert_log_exact "$label" "$logfile" "$@"
}

assert_no_success() {
  local label="$1"
  local output="$2"
  if grep -Eq 'No deployment performed|rollout-preflight ok' "$output"; then
    fail "$label omits success message"
  else
    pass "$label omits success message"
  fi
}

# Allow exact read-only "compose up --help"; reject every other compose up and all mutations.
assert_mutation_free() {
  local label="$1"
  local logfile="$2"
  local filtered
  filtered="$(grep -vxF 'compose up --help' "$logfile" || true)"
  if grep -Eq \
    '^EXECUTED deploy entrypoint$|compose (pull|up|down|rm|kill|restart)|(^| )login( |$)|(^| )logout( |$)|(^| )run( |$)|(^| )exec( |$)|network (create|rm)|prune|:(latest|main|master)($|[^0-9a-f])' \
    <<< "$filtered"; then
    fail "$label contains forbidden mutation command"
  else
    pass "$label is mutation-free (compose up --help allow-listed)"
  fi
}

SOURCE_ROOT=""
DEPLOY_ROOT=""
DEPLOY_SCRIPT=""
APP_DIR=""
FAKE_BIN=""
CMD_LOG=""
MARKER=""

setup_trees() {
  SOURCE_ROOT="$TEST_TEMP/reviewed"
  DEPLOY_ROOT="$TEST_TEMP/srv/apps"
  DEPLOY_SCRIPT="$TEST_TEMP/srv/deploy.sh"
  APP_DIR="$DEPLOY_ROOT/twitter-deck"
  MARKER="$TEST_TEMP/marker-created"
  CMD_LOG="$TEST_TEMP/cmd.log"

  mkdir -p "$SOURCE_ROOT/ops" "$APP_DIR"
  cp -- "$OPS_DIR/compose.yml" "$SOURCE_ROOT/ops/compose.yml"
  cat > "$SOURCE_ROOT/ops/deploy.sh" <<'SCRIPT'
#!/usr/bin/env bash
printf 'EXECUTED deploy entrypoint\n' >> "${FAKE_CMD_LOG:?}"
exit 97
SCRIPT
  cp -- "$OPS_DIR/compose.yml" "$APP_DIR/compose.yml"
  cp -- "$SOURCE_ROOT/ops/deploy.sh" "$DEPLOY_SCRIPT"
  chmod +x "$SOURCE_ROOT/ops/deploy.sh" "$DEPLOY_SCRIPT"
  : > "$CMD_LOG"
  rm -f -- "$MARKER"
}

make_fakes() {
  FAKE_BIN="$TEST_TEMP/fake-bin"
  mkdir -p "$FAKE_BIN"

  cat > "$FAKE_BIN/cmp" <<'SCRIPT'
#!/usr/bin/env bash
set -u
printf 'cmp %s\n' "$*" >> "${FAKE_CMD_LOG:?}"
exec /usr/bin/cmp "$@"
SCRIPT
  chmod +x "$FAKE_BIN/cmp"

  cat > "$FAKE_BIN/getent" <<'SCRIPT'
#!/usr/bin/env bash
set -u
printf 'getent %s\n' "$*" >> "${FAKE_CMD_LOG:?}"
if [[ "${FAKE_GETENT_FAIL:-0}" == "1" ]]; then
  exit 1
fi
host="${2:-}"
ip="${FAKE_DNS_IPV4:-203.0.113.10}"
printf '%s STREAM %s\n' "$ip" "$host"
printf '%s DGRAM  %s\n' "$ip" "$host"
exit 0
SCRIPT
  chmod +x "$FAKE_BIN/getent"

  cat > "$FAKE_BIN/docker" <<'SCRIPT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_CMD_LOG:?}"
mode="${FAKE_DOCKER_FAIL:-none}"
server_version="${FAKE_SERVER_VERSION:-27.5.1}"
compose_version="${FAKE_COMPOSE_VERSION:-2.29.0}"
edge_net_id="${FAKE_EDGE_NETWORK_ID:-net-edge-0123456789abcdef}"
release_sha="${FAKE_RELEASE_SHA:?}"
rollback_sha="${FAKE_ROLLBACK_SHA:?}"

running_fmt='inspect --type container --format {{.State.Running}}'
edge_fmt='inspect --type container --format {{with index .NetworkSettings.Networks "edge"}}{{.NetworkID}}{{end}}'
cmd_fmt='inspect --type container --format {{range .Config.Cmd}}{{println .}}{{end}}'

# Failure injection (exact command match where needed).
case "$mode" in
  info)
    [[ "$*" == "info --format {{.ServerVersion}}" ]] && exit 41
    ;;
  compose_version)
    [[ "$*" == "compose version --short" ]] && exit 42
    ;;
  missing_wait)
    if [[ "$*" == "compose up --help" ]]; then
      printf 'Usage: docker compose up [OPTIONS] [SERVICE...]\n'
      exit 0
    fi
    ;;
  edge_network_inspect)
    [[ "$*" == "network inspect --format {{.Name}} edge" ]] && exit 43
    ;;
  wrong_edge_network)
    if [[ "$*" == "network inspect --format {{.Name}} edge" ]]; then
      printf 'not-edge\n'
      exit 0
    fi
    ;;
  stopped_traefik)
    if [[ "$*" == "$running_fmt "* ]]; then
      printf 'false\n'
      exit 0
    fi
    ;;
  missing_edge_attachment)
    if [[ "$*" == "$edge_fmt "* ]]; then
      printf '\n'
      exit 0
    fi
    ;;
  edge_inspect_fail)
    [[ "$*" == "$edge_fmt "* ]] && exit 44
    ;;
  resolver_le_absent)
    if [[ "$*" == "$cmd_fmt "* ]]; then
      printf 'traefik\n--providers.docker=true\n'
      exit 0
    fi
    ;;
  compose_config)
    [[ "$*" == "compose config --quiet" ]] && exit 45
    ;;
  wrong_service)
    if [[ "$*" == "compose config --services" ]]; then
      printf 'app\nworker\n'
      exit 0
    fi
    ;;
  wrong_image)
    if [[ "$*" == "compose config --images" ]]; then
      printf 'ghcr.io/fallrising/obechow:latest\n'
      exit 0
    fi
    ;;
  release_manifest)
    [[ "$*" == "manifest inspect ghcr.io/fallrising/obechow:${release_sha}" ]] && exit 46
    ;;
  rollback_manifest)
    [[ "$*" == "manifest inspect ghcr.io/fallrising/obechow:${rollback_sha}" ]] && exit 47
    ;;
esac

case "$*" in
  "info --format {{.ServerVersion}}")
    printf '%s\n' "$server_version"
    exit 0
    ;;
  "compose version --short")
    printf '%s\n' "$compose_version"
    exit 0
    ;;
  "compose up --help")
    printf 'Usage: docker compose up [OPTIONS] [SERVICE...]\n\nOptions:\n      --wait   Wait for services to be running|healthy\n'
    exit 0
    ;;
  "network inspect --format {{.Name}} edge")
    printf 'edge\n'
    exit 0
    ;;
  "$running_fmt "*)
    printf 'true\n'
    exit 0
    ;;
  "$edge_fmt "*)
    printf '%s\n' "$edge_net_id"
    exit 0
    ;;
  "$cmd_fmt "*)
    printf 'traefik\n--certificatesresolvers.le.acme.httpchallenge=true\n--certificatesresolvers.le.acme.httpchallenge.entrypoint=web\n'
    exit 0
    ;;
  "compose config --quiet")
    exit 0
    ;;
  "compose config --services")
    printf 'app\n'
    exit 0
    ;;
  "compose config --images")
    printf 'ghcr.io/fallrising/obechow:%s\n' "$release_sha"
    exit 0
    ;;
  "manifest inspect ghcr.io/fallrising/obechow:${release_sha}"|\
  "manifest inspect ghcr.io/fallrising/obechow:${rollback_sha}")
    printf '{"schemaVersion":2}\n'
    exit 0
    ;;
esac

printf 'unexpected docker invocation: %s\n' "$*" >&2
exit 99
SCRIPT
  chmod +x "$FAKE_BIN/docker"
}

# Exact ordered success oracle (read-only sequence).
success_commands() {
  local release="${1:-$RELEASE_SHA}"
  local host="${2:-$APP_HOST}"
  local traefik="${3:-$TRAEFIK_CONTAINER}"
  cat <<EOF
cmp $SOURCE_ROOT/ops/compose.yml $APP_DIR/compose.yml
cmp $SOURCE_ROOT/ops/deploy.sh $DEPLOY_SCRIPT
info --format {{.ServerVersion}}
compose version --short
compose up --help
network inspect --format {{.Name}} edge
inspect --type container --format {{.State.Running}} $traefik
inspect --type container --format {{with index .NetworkSettings.Networks "edge"}}{{.NetworkID}}{{end}} $traefik
inspect --type container --format {{range .Config.Cmd}}{{println .}}{{end}} $traefik
compose config --quiet
compose config --services
compose config --images
getent ahostsv4 $host
manifest inspect ${IMAGE_REPO}:$release
manifest inspect ${IMAGE_REPO}:$ROLLBACK_SHA
EOF
}

# Prefix helpers for failure-stop assertions (shared building blocks).
prefix_through() {
  # Prints success_commands lines 1..N (1-based inclusive).
  local n="$1"
  mapfile -t _all < <(success_commands)
  local i
  for ((i = 0; i < n && i < ${#_all[@]}; i++)); do
    printf '%s\n' "${_all[i]}"
  done
}

run_preflight() {
  local output="$1"
  shift
  local rc=0
  : > "$CMD_LOG"
  rm -f -- "$MARKER"

  if [[ ! -f "$PREFLIGHT" ]]; then
    printf 'ops/rollout-preflight.sh is absent\n' > "$output"
    return 127
  fi

  env -u DEPLOY_ENABLED \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    FAKE_CMD_LOG="$CMD_LOG" \
    FAKE_DOCKER_FAIL="${FAKE_DOCKER_FAIL:-none}" \
    FAKE_GETENT_FAIL="${FAKE_GETENT_FAIL:-0}" \
    FAKE_DNS_IPV4="${FAKE_DNS_IPV4:-$EXPECTED_DNS_IPV4}" \
    FAKE_SERVER_VERSION="$FAKE_SERVER_VERSION" \
    FAKE_COMPOSE_VERSION="$FAKE_COMPOSE_VERSION" \
    FAKE_EDGE_NETWORK_ID="$FAKE_EDGE_NETWORK_ID" \
    FAKE_RELEASE_SHA="$RELEASE_SHA" \
    FAKE_ROLLBACK_SHA="$ROLLBACK_SHA" \
    APP_HOST="${CASE_APP_HOST-$APP_HOST}" \
    EXPECTED_DNS_IPV4="${CASE_DNS-$EXPECTED_DNS_IPV4}" \
    TRAEFIK_CONTAINER="${CASE_TRAEFIK-$TRAEFIK_CONTAINER}" \
    OBECHOW_SOURCE_ROOT="${CASE_SOURCE-$SOURCE_ROOT}" \
    OBECHOW_DEPLOY_ROOT="${CASE_DEPLOY_ROOT-$DEPLOY_ROOT}" \
    OBECHOW_DEPLOY_SCRIPT="${CASE_DEPLOY_SCRIPT-$DEPLOY_SCRIPT}" \
    bash "$PREFLIGHT" "$@" > "$output" 2>&1 || rc=$?
  return "$rc"
}

# Isolated failure: non-zero, no external commands, no success text.
assert_isolated() {
  local label="$1"
  local output="$2"
  local rc="$3"
  [[ "$rc" -ne 0 ]] && pass "$label exits non-zero" || fail "$label exits non-zero"
  [[ ! -s "$CMD_LOG" ]] && pass "$label invokes no external command" \
    || fail "$label invokes no external command: [$(tr '\n' ' ' < "$CMD_LOG")]"
  assert_no_success "$label" "$output"
}

assert_marker_absent() {
  local label="$1"
  [[ ! -e "$MARKER" ]] && pass "$label does not create marker" || fail "$label does not create marker"
}

# Run preflight with default args (or provided), assert isolated failure.
run_isolated_args() {
  local label="$1"
  shift
  local output="$TEST_TEMP/isolated.out"
  local rc=0
  unset CASE_APP_HOST CASE_DNS CASE_TRAEFIK CASE_SOURCE CASE_DEPLOY_ROOT CASE_DEPLOY_SCRIPT
  FAKE_DOCKER_FAIL=none FAKE_GETENT_FAIL=0 \
    run_preflight "$output" "$@" || rc=$?
  assert_isolated "$label" "$output" "$rc"
}

# Run preflight with default SHAs; CASE_* env vars select invalid env/overrides.
run_isolated_env() {
  local label="$1"
  local output="$TEST_TEMP/isolated-env.out"
  local rc=0
  FAKE_DOCKER_FAIL=none FAKE_GETENT_FAIL=0 \
    run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
  assert_isolated "$label" "$output" "$rc"
  unset CASE_APP_HOST CASE_DNS CASE_TRAEFIK CASE_SOURCE CASE_DEPLOY_ROOT CASE_DEPLOY_SCRIPT
}

# Unset one required env var and assert isolation (bypasses CASE_* defaults).
run_missing_env() {
  local label="$1"
  local unset_var="$2"
  local output="$TEST_TEMP/missing-env.out"
  local rc=0
  : > "$CMD_LOG"
  if [[ ! -f "$PREFLIGHT" ]]; then
    printf 'ops/rollout-preflight.sh is absent\n' > "$output"
    rc=127
  else
    local -a environment=(
      env -u DEPLOY_ENABLED -u "$unset_var"
      "PATH=$FAKE_BIN:/usr/bin:/bin"
      "FAKE_CMD_LOG=$CMD_LOG"
      "FAKE_RELEASE_SHA=$RELEASE_SHA"
      "FAKE_ROLLBACK_SHA=$ROLLBACK_SHA"
      "FAKE_SERVER_VERSION=$FAKE_SERVER_VERSION"
      "FAKE_COMPOSE_VERSION=$FAKE_COMPOSE_VERSION"
      "FAKE_EDGE_NETWORK_ID=$FAKE_EDGE_NETWORK_ID"
      "OBECHOW_SOURCE_ROOT=$SOURCE_ROOT"
      "OBECHOW_DEPLOY_ROOT=$DEPLOY_ROOT"
      "OBECHOW_DEPLOY_SCRIPT=$DEPLOY_SCRIPT"
    )
    [[ "$unset_var" == APP_HOST ]] || environment+=("APP_HOST=$APP_HOST")
    [[ "$unset_var" == EXPECTED_DNS_IPV4 ]] || environment+=("EXPECTED_DNS_IPV4=$EXPECTED_DNS_IPV4")
    [[ "$unset_var" == TRAEFIK_CONTAINER ]] || environment+=("TRAEFIK_CONTAINER=$TRAEFIK_CONTAINER")

    "${environment[@]}" \
      bash "$PREFLIGHT" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" > "$output" 2>&1 || rc=$?
  fi
  assert_isolated "$label" "$output" "$rc"
}

# ---------------------------------------------------------------------------
printf '=== 0. Existence (RED gate) ===\n'
if [[ -f "$PREFLIGHT" ]]; then
  pass "ops/rollout-preflight.sh exists"
else
  fail "ops/rollout-preflight.sh is absent"
fi

printf '=== 1. Syntax checks ===\n'
bash -n "$0" && pass "test script syntax" || fail "test script syntax"
if [[ -f "$PREFLIGHT" ]]; then
  bash -n "$PREFLIGHT" && pass "preflight script syntax" || fail "preflight script syntax"
else
  fail "preflight script syntax (file absent)"
fi

setup_trees
make_fakes

printf '=== 2. Valid success path (P06-BDD-01) ===\n'
success_path_test() {
  local output="$TEST_TEMP/success.out"
  local rc=0
  FAKE_DOCKER_FAIL=none FAKE_GETENT_FAIL=0 \
    run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?

  [[ "$rc" -eq 0 ]] && pass "valid preflight exits zero" || fail "valid preflight exits zero: got $rc"

  local -a expected=()
  mapfile -t expected < <(success_commands)
  assert_log_exact "valid preflight has exact command sequence" "$CMD_LOG" "${expected[@]}"

  local ok_line="rollout-preflight ok twitter-deck $RELEASE_SHA $ROLLBACK_SHA $APP_HOST"
  grep -qFx "$ok_line" "$output" \
    && pass "success reports exact app release rollback host" \
    || fail "success reports exact app release rollback host (want: $ok_line)"
  grep -qFx 'No deployment performed' "$output" \
    && pass "success states no deployment performed" \
    || fail "success states no deployment performed"
  assert_mutation_free "success log" "$CMD_LOG"
}
success_path_test

printf '=== 3. Invalid input isolation (P06-BDD-02) ===\n'
invalid_input_test() {
  run_isolated_args "zero arguments"
  run_isolated_args "one argument" twitter-deck
  run_isolated_args "two arguments" twitter-deck "$RELEASE_SHA"
  run_isolated_args "four arguments" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" extra

  run_isolated_args "unknown app" other-app "$RELEASE_SHA" "$ROLLBACK_SHA"
  run_isolated_args "shell-like app" 'twitter-deck;touch' "$RELEASE_SHA" "$ROLLBACK_SHA"

  run_isolated_args "empty release SHA" twitter-deck "" "$ROLLBACK_SHA"
  run_isolated_args "empty rollback SHA" twitter-deck "$RELEASE_SHA" ""
  run_isolated_args "short release SHA" twitter-deck abc123 "$ROLLBACK_SHA"
  run_isolated_args "short rollback SHA" twitter-deck "$RELEASE_SHA" abc123
  run_isolated_args "uppercase release SHA" twitter-deck ABCDEF0123456789ABCDEF0123456789ABCDEF01 "$ROLLBACK_SHA"
  run_isolated_args "uppercase rollback SHA" twitter-deck "$RELEASE_SHA" ABCDEF0123456789ABCDEF0123456789ABCDEF01
  run_isolated_args "non-hex release SHA" twitter-deck zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz "$ROLLBACK_SHA"
  run_isolated_args "non-hex rollback SHA" twitter-deck "$RELEASE_SHA" zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz
  run_isolated_args "mutable release tag" twitter-deck latest "$ROLLBACK_SHA"
  run_isolated_args "mutable rollback tag" twitter-deck "$RELEASE_SHA" latest
  run_isolated_args "equal release and rollback" twitter-deck "$RELEASE_SHA" "$RELEASE_SHA"

  local shell_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;touch ${MARKER}"
  run_isolated_args "shell-like release SHA" twitter-deck "$shell_sha" "$ROLLBACK_SHA"
  assert_marker_absent "shell-like release SHA"
  run_isolated_args "shell-like rollback SHA" twitter-deck "$RELEASE_SHA" "$shell_sha"
  assert_marker_absent "shell-like rollback SHA"

  run_missing_env "missing APP_HOST" APP_HOST
  run_missing_env "missing EXPECTED_DNS_IPV4" EXPECTED_DNS_IPV4
  run_missing_env "missing TRAEFIK_CONTAINER" TRAEFIK_CONTAINER

  CASE_APP_HOST='' run_isolated_env "empty hostname"
  CASE_APP_HOST='App.Example.TEST' run_isolated_env "uppercase hostname"
  CASE_APP_HOST='https://app.example.test' run_isolated_env "scheme-prefixed hostname"
  CASE_APP_HOST='app.example.test/path' run_isolated_env "slash-containing hostname"
  CASE_APP_HOST='app..example.test' run_isolated_env "empty-label hostname"
  CASE_APP_HOST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example.test' \
    run_isolated_env "overlong-label hostname"
  CASE_APP_HOST='-app.example.test' run_isolated_env "label-start hyphen hostname"
  CASE_APP_HOST='app-.example.test' run_isolated_env "label-end hyphen hostname"
  # 255 characters total while every individual label remains valid.
  CASE_APP_HOST="$(printf 'a%.0s' {1..63}).$(printf 'b%.0s' {1..63}).$(printf 'c%.0s' {1..63}).$(printf 'd%.0s' {1..63})" \
    run_isolated_env "overlong total hostname"
  CASE_APP_HOST="app.example.test;touch ${MARKER}" run_isolated_env "shell-like hostname"
  assert_marker_absent "shell-like hostname"

  CASE_DNS='' run_isolated_env "empty IPv4"
  CASE_DNS='1.2.3' run_isolated_env "invalid IPv4"
  CASE_DNS='256.0.0.1' run_isolated_env "out-of-range IPv4"
  CASE_DNS='203.0.113.10;touch' run_isolated_env "shell-like IPv4"

  CASE_TRAEFIK='' run_isolated_env "empty Traefik container"
  CASE_TRAEFIK='-traefik' run_isolated_env "leading-hyphen Traefik container"
  CASE_TRAEFIK="traefik;touch ${MARKER}" run_isolated_env "shell-like Traefik container"
  assert_marker_absent "shell-like Traefik container"
  CASE_TRAEFIK='traefik/evil' run_isolated_env "invalid Traefik container chars"

  CASE_SOURCE='' run_isolated_env "empty source root override"
  CASE_DEPLOY_ROOT='' run_isolated_env "empty deploy-root override"
  CASE_DEPLOY_SCRIPT='' run_isolated_env "empty deploy-script override"
  CASE_SOURCE='relative/source' run_isolated_env "relative source root override"
  CASE_DEPLOY_ROOT='relative/apps' run_isolated_env "relative deploy-root override"
  CASE_DEPLOY_SCRIPT='relative/deploy.sh' run_isolated_env "relative deploy-script override"
}
invalid_input_test

printf '=== 4. Artifact presence and drift (P06-BDD-03) ===\n'
artifact_and_drift_test() {
  local output="$TEST_TEMP/drift.out"
  local rc

  run_presence_fail() {
    local label="$1"
    rc=0
    FAKE_DOCKER_FAIL=none run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
    assert_isolated "$label" "$output" "$rc"
  }

  setup_trees; make_fakes
  rm -rf -- "$APP_DIR"
  run_presence_fail "missing app directory"

  setup_trees; make_fakes
  rm -f -- "$APP_DIR/compose.yml"
  run_presence_fail "missing Compose file"

  setup_trees; make_fakes
  rm -f -- "$DEPLOY_SCRIPT"
  run_presence_fail "missing deploy entrypoint"

  setup_trees; make_fakes
  chmod a-x "$DEPLOY_SCRIPT"
  run_presence_fail "non-executable deploy entrypoint"

  setup_trees; make_fakes
  printf '\n# drift\n' >> "$APP_DIR/compose.yml"
  rc=0
  FAKE_DOCKER_FAIL=none run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
  [[ "$rc" -ne 0 ]] && pass "Compose mismatch exits non-zero" || fail "Compose mismatch exits non-zero"
  mapfile -t _p < <(prefix_through 1)
  assert_log_prefix "Compose mismatch stops at compose cmp" "$CMD_LOG" "${_p[@]}"
  assert_no_success "Compose mismatch" "$output"

  setup_trees; make_fakes
  printf '\n# drift\n' >> "$DEPLOY_SCRIPT"
  rc=0
  FAKE_DOCKER_FAIL=none run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
  [[ "$rc" -ne 0 ]] && pass "deploy mismatch exits non-zero" || fail "deploy mismatch exits non-zero"
  mapfile -t _p < <(prefix_through 2)
  assert_log_prefix "deploy mismatch stops at deploy cmp" "$CMD_LOG" "${_p[@]}"
  assert_no_success "deploy mismatch" "$output"
}
artifact_and_drift_test

printf '=== 5. Failure propagation (P06-BDD-04) ===\n'
failure_propagation_test() {
  local output="$TEST_TEMP/failure.out"
  local rc
  local -a stop

  # N = number of success-oracle commands that must have run when this step fails.
  run_fail_at() {
    local label="$1"
    local mode="$2"
    local n="$3"
    rc=0
    setup_trees
    make_fakes
    FAKE_DOCKER_FAIL="$mode" FAKE_GETENT_FAIL=0 \
      run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
    [[ "$rc" -ne 0 ]] && pass "$label exits non-zero" || fail "$label exits non-zero"
    mapfile -t stop < <(prefix_through "$n")
    assert_log_prefix "$label exact stop prefix" "$CMD_LOG" "${stop[@]}"
    assert_no_success "$label" "$output"
  }

  # Oracle indices (1-based) matching success_commands lines:
  # 1 cmp compose, 2 cmp deploy, 3 info ServerVersion, 4 compose version --short,
  # 5 compose up --help, 6 edge network, 7 Running, 8 edge NetworkID,
  # 9 Cmd lines, 10 config quiet, 11 services, 12 images, 13 getent,
  # 14 release manifest, 15 rollback manifest

  run_fail_at "Docker Engine failure" info 3
  run_fail_at "Compose version failure" compose_version 4
  run_fail_at "missing --wait" missing_wait 5
  run_fail_at "edge network inspect failure" edge_network_inspect 6
  run_fail_at "wrong edge network name" wrong_edge_network 6
  run_fail_at "stopped Traefik" stopped_traefik 7
  run_fail_at "missing edge attachment" missing_edge_attachment 8
  run_fail_at "edge attachment inspect failure" edge_inspect_fail 8
  run_fail_at "resolver le absent" resolver_le_absent 9
  run_fail_at "Compose validation failure" compose_config 10
  run_fail_at "resolved service not exactly app" wrong_service 11
  run_fail_at "resolved image not exact release SHA" wrong_image 12

  # DNS failure / mismatch stop after getent (line 13)
  setup_trees; make_fakes
  rc=0
  FAKE_DOCKER_FAIL=none FAKE_GETENT_FAIL=1 \
    run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
  [[ "$rc" -ne 0 ]] && pass "DNS failure exits non-zero" || fail "DNS failure exits non-zero"
  mapfile -t stop < <(prefix_through 13)
  assert_log_prefix "DNS failure exact stop prefix" "$CMD_LOG" "${stop[@]}"
  assert_no_success "DNS failure" "$output"

  setup_trees; make_fakes
  rc=0
  FAKE_DOCKER_FAIL=none FAKE_GETENT_FAIL=0 FAKE_DNS_IPV4="198.51.100.20" \
    run_preflight "$output" twitter-deck "$RELEASE_SHA" "$ROLLBACK_SHA" || rc=$?
  [[ "$rc" -ne 0 ]] && pass "DNS address mismatch exits non-zero" || fail "DNS address mismatch exits non-zero"
  mapfile -t stop < <(prefix_through 13)
  assert_log_prefix "DNS address mismatch exact stop prefix" "$CMD_LOG" "${stop[@]}"
  assert_no_success "DNS address mismatch" "$output"

  run_fail_at "release manifest failure" release_manifest 14
  run_fail_at "rollback manifest failure" rollback_manifest 15
}
failure_propagation_test

printf '\n=== Result ===\n'
printf 'Passed: %d\nFailed: %d\n' "$PASS_COUNT" "$FAIL_COUNT"
exit $((FAIL_COUNT > 0 ? 1 : 0))
