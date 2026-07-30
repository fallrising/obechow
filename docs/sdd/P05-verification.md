---
document_type: verification-report
node_id: P05
status: pr-passed
spec_revision: 1
implementation_commit: 42282bdc113f65d5ef5871bbf098ef01a92c7f29
merge_commit: pending
pull_request: 3
pr_validation_commit: cb2be5cbb5047341458789d41132a3ea5430f3f6
pr_validation_run: 30501994218
compose_sha256: 9103396c54617315f98aed5924fbdfe627461fb196ed28586a669be338e2e43e
deploy_sha256: 6f36d211195b065119cea765622b097105b156e40562be578b1f38b366b966be
test_sha256: 61f925c67fbca617b71ad6bf601575d55762b1648530fb0549cd92b0985672a9
workflow_sha256: ea7370a269aec998e12acd03a2f873f4952bb5e8112da3694f8f1529f4fb6115
local_image_id: sha256:a30e0777be62e979e9e0ee61c8da4a5a28246be4bef4ffd5f1568dc468b3f62b
reviewer: codex
verified_at: 2026-07-29
---

# P05 verification report

## Current conclusion

All repository, local runtime, and pull-request gates pass. The deployment
bundle remains in `verifying` until the implementation is merged. No VPS
installation or live deployment is claimed.

## Requirement evidence

| Requirement | Evidence | Result |
|---|---|---|
| Exact immutable deployment | argument and exact fake-Docker sequence assertions | passed locally |
| Invalid input isolation | wrong arity/app/SHA/path cases leave Docker log empty | passed locally |
| Failure propagation | config, pull, and up failures stop at the failing command | passed locally |
| Persistent private service | resolved Compose JSON plus A→B SQLite replacement | passed locally |
| Bounded production scope | service-scoped commands and forbidden-operation assertions | passed locally |
| CI regression gate | identical test step precedes both workflow image builds | passed online |

## Commands

```text
tests/ops/deployment_bundle_test.sh
/tmp/actionlint .github/workflows/deploy.yml
docker compose --env-file ops/.env.example -f ops/compose.yml config --format json
docker build -t obechow:p05-verification .
git diff --check
focused docker run/exec/inspect replacement smoke
```

The contract suite reports 42 passed assertions and zero failures.
`actionlint`, Compose resolution, image build, and whitespace checks all exit
zero.

## Delegated review findings

| Severity | Finding | Resolution |
|---|---|---|
| high | delegated Traefik matcher omitted required backticks | use resolved `Host(\`hostname\`)` rule |
| medium | `.env` could replace the whole image reference | fix GHCR repository in Compose; expose only required SHA tag |
| medium | test file was not executable for its workflow invocation | commit mode `100755` |
| medium | delegated Compose assertions checked keys, not values | parse and assert exact resolved Compose JSON |
| medium | failure tests did not prove later commands stopped | assert exact log prefix for every injected failure |
| low | resolver name drifted from existing Traefik contract | align on `le` |

No delegated finding remains unresolved.

## Runtime finding and correction

The first read-only smoke failed before application startup. Docker mounted a
plain `/tmp` tmpfs with `noexec`, and Xerial SQLite JDBC could not load its
extracted native library. The accepted correction:

- leaves general `/tmp` as `rw,noexec,nosuid,nodev,size=64m`;
- adds `/sqlite-tmp` as `rw,exec,nosuid,nodev,size=16m`;
- sets `-Dorg.sqlite.tmpdir=/sqlite-tmp`;
- keeps the container root filesystem read-only.

After correction, container A became healthy, accepted a post, and read it
back. Container A was removed; container B started from the same bind mount,
became healthy, and returned the same id=1 post. The bind directory contained
`app.db`, `app.db-wal`, and `app.db-shm`. Both containers and the temporary data
directory were then removed.

## Online gate

[GitHub Actions run 30501994218](https://github.com/fallrising/obechow/actions/runs/30501994218)
completed successfully for PR #3 at head
`cb2be5cbb5047341458789d41132a3ea5430f3f6`:

| Job | Result |
|---|---|
| `validate` | success; deployment tests and production image build passed |
| `publish` | skipped |
| `deploy` | skipped |

The remaining repository gate is to merge the reviewed implementation and
record the merge plus `main` workflow evidence in the closure report update.

Actual VPS installation, Traefik/DNS reachability, SSH secrets, and enabling
`DEPLOY_ENABLED` remain Phase 6 external work.
