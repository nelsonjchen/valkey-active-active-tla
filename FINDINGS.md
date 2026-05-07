# bet0x Valkey Active/Active Audit Report

Date: 2026-05-06

## Scope

Reviewed implementation:
- Original fork target: `bet0x/valkey` branch `unstable`, commit `9b2284900efa42e205e421ed6307019da5b15497`.
- Rebased audit branch: `audit/bet0x-active-active-fix-rebased`, based on `valkey-io/valkey:unstable` commit `6c9d7fc263dd4dfe07460f7ed6de63295890b77a`.
- Backup branch before rebase: `audit/bet0x-active-active-fix-pre-rebase`.

The reviewed implementation adds active/active replication controls, `REPLICAOF ADD/REMOVE`, internal `RREPLAY`, `MVCCRESTORE`, MVCC key clocks, replay dedupe, peer replay queues, RDB AUX metadata, and INFO/ROLE telemetry.

## Current Result

The rebased branch builds and the focused active/active suites pass after local fixes. This pass adds the first productionization guardrails: an explicit command semantics matrix, debug-only access to `MVCCRESTORE`, unlimited MVCC RDB clock persistence by default, and layered TLA+ specs for core replay and future typed merge semantics.

The correctness envelope is still deliberately narrow:
- Allowed local/replay writes: `SET`, `MSET`, single-key `DEL`, and internal `MVCCRESTORE`.
- Rejected before mutation: streams, functions, relative TTL mutation, transactions, RMW commands such as `INCR`/`APPEND`/`HINCRBY`/`ZINCRBY`, partial collection mutations such as `HSET`/`ZADD`/`SADD`/`LPUSH`, `RENAME`, and multi-key `DEL`.

That narrower policy is intentional. With key-level LWW/MVCC, partial collection deltas and multi-key operations can otherwise converge in some traces while diverging in others.

## Verification

Build:
- `make -j$(sysctl -n hw.ncpu)` passed on the rebased branch.

Focused tests:

| Test | Result |
| --- | --- |
| `unit/rreplay` | 3 passed, 0 failed |
| `integration/replication-multimaster-rreplay` | 19 passed, 0 failed |
| `integration/replication-multimaster` | 14 passed, 0 failed |
| `integration/replication-multimaster-upstreams` | 11 passed, 0 failed |
| `integration/replication-multimaster-topologies` | 9 passed, 0 failed |
| `integration/replication-active` | 5 passed, 0 failed |
| `integration/multimaster-psync` | 4 passed, 0 failed |
| `integration/psync2-reg-multimaster` | 5 passed, 0 failed |

Formal/model checks:
- `audit/formal/MultiMaster-supported.cfg`: no TLC invariant violations; 5,510,617 states generated, 1,167,907 distinct states.
- `audit/formal/MultiMaster-unsupported.cfg`: no TLC invariant violations; 3,515 states generated, 925 distinct states.
- `audit/formal/CoreReplay.cfg`: no TLC invariant violations; 42,793 states generated, 5,905 distinct states.
- `audit/formal/TypeSemantics.cfg`: no TLC invariant violations; 924,305 states generated, 181,804 distinct states.
- Invariants checked: type safety, convergence after network quiescence, and no own-origin in-flight messages.

Simulator:
- `audit/sim/mm_sim.py --runs 2000 --steps 80`: no convergence failures after draining the network.
- Simulator now models `SET`, `MSET`, single-key `DEL`, duplicate delivery, partitions/heal, restart with optional dedupe loss, own-origin drops, rejected `INCR`, and rejected unsupported/partial commands.

## Fixed Locally

### 1. Unsupported Writes Mutated Locally Before Being Dropped

Pre-fix behavior: unsupported active/active writes could execute locally, then fail later in `replicationFeedPrimaryWithRReplay`. The client saw success while peers never received an equivalent replay frame.

Shortest repro:
1. Enable `active-replica yes`, `multi-master yes`, `replica-read-only no` on two peers.
2. Issue `XADD s * f v` or `EXPIRE k 10` to one peer.
3. The local node mutates; the peer never receives a replay-safe operation.

Fix:
- `src/server.c` now checks `replicationCanForwardCommandWithRReplay(...)` before executing local active/active writes.
- Regression tests assert rejected `XADD` and relative `EXPIRE` leave both peers unchanged.

### 2. RMW Commands Were Canonicalized After Mutation

Pre-fix behavior: `INCR`, `APPEND`, `HINCRBY`, `ZINCRBY`, and similar commands executed locally, then were forwarded as absolute writes. This converges but loses update semantics.

Shortest model trace:
1. A runs `INCR ctr`, canonicalized as `SET ctr 1`.
2. B concurrently runs `INCR ctr`, canonicalized as `SET ctr 1`.
3. Both nodes converge to `1`; a counter merge would require `2`.

Fix:
- Local RMW commands are rejected before mutation in active/active mode.
- Raw incoming `RREPLAY` frames containing RMW commands remain rejected.
- The stale post-mutation canonicalization path was removed from forwarding.

### 3. Partial Collection Mutations And Multi-Key Operations Were Still Too Broad

Bug found during follow-through: the support check still accepted any write command with key metadata unless explicitly blocked. That allowed unsafe operations such as `HSET`, `ZADD`, `SADD`, `LPUSH`, `RENAME`, and multi-key `DEL`.

Shortest divergence shape:
1. A runs a partial mutation on key `h`, for example `HSET h a 1`.
2. B concurrently runs a different mutation on the same logical object, for example `HSET h b 2`, or a competing write to one key in a multi-key command.
3. Key-level MVCC can reject the stale incoming delta on one side, but the already-applied local field/member remains on the other side. The datasets can quiesce with different object contents.

Fix:
- `src/replication.c` now uses an explicit command semantics classifier matching `audit/COMMAND_MATRIX.md`.
- Current supported state is `SET`, `MSET`, single-key `DEL`, and internal/debug `MVCCRESTORE`.
- Regression tests assert `HSET`, `ZADD`, `SADD`, `LPUSH`, `RENAME`, and multi-key `DEL` are rejected before mutation.

### 4. Internal MVCC Restore Was Exposed To Normal Clients

Pre-fix behavior: `MVCCRESTORE` was registered as a dangerous write command but callable by normal clients with sufficient ACL permission.

Fix:
- `MVCCRESTORE` is now rejected for normal clients unless `active-replica-debug-commands yes` is explicitly enabled.
- RREPLAY payload execution still works because replay uses a fake/internal client.
- INFO replication exposes `active_replica_debug_commands` so the unsafe debug surface is visible.

## Open Risks

### MVCC Clock Persistence Cap

`mvcc-rdb-clock-max-entries` can cap persisted key clocks if configured to a positive value. The production default is now `0` (unlimited) so correctness-critical metadata is not silently dropped by default. The cap remains a debug/operational escape hatch and still degrades stale-write protection when deliberately enabled.

### AOF-Only Restart Semantics

The audit focused on RDB AUX metadata. AOF-only and AOF rewrite behavior still need direct testing. If the dataset is replayed without the corresponding MVCC/dedupe metadata, stale replay protection can be weaker after restart.

### Replay ACK And Queue Semantics

The replay queue has focused tests for drain and overflow/fullsync request behavior, but ACK handling is still delicate. The implementation advances `replay_last_acked_id` from peer integer replies and drains pending replay frames in FIFO order. A stronger design should specify behavior for duplicate ACKs, unexpected ACK ids, reconnect races, and fullsync requests while new writes arrive.

### Dedupe Bound

`RREPLAY_DEDUP_MAX_ENTRIES` is fixed at 10,000 entries. This bounds memory but means old duplicate frames can be accepted again after eviction. MVCC freshness usually protects values, but this should be documented as bounded idempotence, not permanent dedupe.

### Upstream Readiness

The patch remains large and invasive across replication, RDB, command metadata, config, tests, and INFO/ROLE output. Even after rebase, it needs a design document and a staged review plan before it is practical for upstream review.

## Maintainer Notes

The main issue is not whether a small active/active subset can be made to converge. The model and tests support that for a narrow set. The issue is command semantics: Valkey commands that mutate part of an object or multiple keys are not automatically safe under command-level key MVCC. They need one of:
- rejection before mutation,
- full-value canonical replay with clear LWW semantics,
- command-specific merge logic,
- or a CRDT/type-level design.

The local fixes choose rejection. That makes the prototype more honest and easier to evaluate.

## Reproduce

```bash
git checkout audit/bet0x-active-active-fix-rebased
make -j$(sysctl -n hw.ncpu)
./runtest --single unit/rreplay
./runtest --single integration/replication-multimaster-rreplay
./runtest --single integration/replication-multimaster
./runtest --single integration/replication-multimaster-upstreams
./runtest --single integration/replication-multimaster-topologies
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/MultiMaster-supported.cfg audit/formal/MultiMaster.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/MultiMaster-unsupported.cfg audit/formal/MultiMaster.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/CoreReplay.cfg audit/formal/CoreReplay.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/TypeSemantics.cfg audit/formal/TypeSemantics.tla
audit/sim/mm_sim.py --runs 2000 --steps 80
```
