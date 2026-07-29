# Obechow SDD

This directory is the execution authority for new delivery phases.

The document order is:

1. the node spec defines observable behaviour and scope;
2. the implementation plan defines design, ownership, and rollback;
3. the test plan maps every behaviour to evidence;
4. task specs bound individual implementation changes;
5. a verification report records results without changing requirements.

`docs/TECH_SPEC.md` remains the product and architecture overview. An SDD node
may refine one delivery phase, but it must not silently expand the MVP product
scope. If implementation needs a different observable contract, update and
review the node spec before changing production files.

## Status lifecycle

`draft → ready → implementing → verifying → done`

No implementation task starts before its node is `ready`. A node is `done` only
after its verification report is committed with reproducible evidence.
