---
document_type: verification-report
node_id: P06
status: pending
spec_revision: 2
reviewer: codex
---

# P06 verification report

## Current conclusion

Verification has not started. No VPS installation or live deployment is
claimed.

## Evidence ledger

| Requirement | Evidence | Result |
|---|---|---|
| Input isolation | 216-assertion focused contract | passed locally |
| Reviewed artifact identity | exact comparison and drift-stop assertions | passed locally |
| Docker/Compose/edge/Traefik checks | exact command and failure-prefix assertions | passed locally |
| DNS and immutable manifest checks | exact value and failure-prefix assertions | passed locally |
| Read-only command scope | exact allow-listed success log | passed locally |
| Local Docker replacement | isolated A-to-B Compose rehearsal | passed locally |
| Pull-request and merged-main workflow | pending | pending |

## Local Docker rehearsal evidence

`tests/ops/rollout_rehearsal_test.sh` built the root production image as
`ghcr.io/fallrising/obechow:59df06fd01796d085e400923329533d8573f5c94`
with local image ID
`sha256:a30e0777be62e979e9e0ee61c8da4a5a28246be4bef4ffd5f1568dc468b3f62b`.
It started an isolated Compose project on a unique bridge network without host
ports or an application-image pull.

Container `2dfc051f...` became healthy, accepted post id `1`, and was
force-recreated as `04f6b3d8...`. The replacement became healthy and returned
the same id, author, and content from the temporary SQLite bind. Both
containers reported:

- read-only root and `no-new-privileges`;
- empty host port bindings and only the unique rehearsal network;
- exact writable `/data` bind;
- `/tmp` as `rw,noexec,nosuid,nodev,size=64m`;
- `/sqlite-tmp` as `rw,exec,nosuid,nodev,size=16m`.

The bind contained `app.db`, `app.db-shm`, and `app.db-wal`. Exact cleanup and
independent post-run queries found no rehearsal container, network, image tag,
temporary directory, or repository `ops/data` directory.

## External activation gate

P06 repository readiness does not authorize a real rollout. Live evidence
requires operator-provided VPS, DNS, Traefik, GHCR, GitHub, smoke, and rollback
inputs listed in `P06-rollout-readiness.md`.
