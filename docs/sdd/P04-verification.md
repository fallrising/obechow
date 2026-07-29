---
document_type: verification-report
node_id: P04
status: local-passed
spec_revision: 1
implementation_commit: 9152e5d6749feba17508159e669c3a8067676492
workflow_sha256: 1ae32591a722a4f47ba80a6075f47ad486201d95bcd5b11d647595c79f6e7491
reviewer: codex
verified_at: 2026-07-29
---

# P04 verification report

## Conclusion

The repository implementation passes every local gate and the delegated code
has been reviewed and corrected. Pull-request execution, GHCR publication, and
VPS deployment remain online gates; Phase 6 is not complete.

## Requirement evidence

| Requirement | Repository evidence | Result |
|---|---|---|
| PR build without credentials | separate `validate` job; workflow permissions are read-only | passed locally |
| Main publishes `latest` and full SHA | `publish` job raw metadata tags | passed locally |
| Deploy disabled by default | exact `DEPLOY_ENABLED == 'true'` job condition | passed locally |
| Trusted exact deployment | fingerprint secret and full SHA remote command | passed locally |
| Serialized deployment | `production-deploy`, `cancel-in-progress: false` | passed locally |
| Immutable dependencies | seven action uses resolve to 40-character commit SHAs | passed locally |

## Commands

```text
/tmp/actionlint .github/workflows/deploy.yml
docker build -t obechow:p04-verification .
git diff --check
focused YAML contract assertions
```

All commands exited zero. The Docker build produced image
`sha256:a30e0777be62e979e9e0ee61c8da4a5a28246be4bef4ffd5f1568dc468b3f62b`
on the verification host.

## Review findings

| Severity | Finding | Resolution |
|---|---|---|
| medium | delegated PR build held `packages: write` | split `validate` and `publish` jobs |
| medium | downloaded SSH binary could float | pin `version: 1.8.2` |
| low | delegated draft used older action major versions | pin current official majors and checkout release by full SHA |

No unresolved local finding remains.

## Pending online evidence

- Pull request run builds without login, push, or SSH steps.
- A `main` run publishes both GHCR tags.
- With deploy disabled, the deploy job is skipped.
- After Phase 5, an enabled deployment runs the exact published SHA on the VPS.
