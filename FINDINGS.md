# bet0x Valkey Active/Active Audit Report

Date: 2026-05-07

## Scope

Reviewed implementation:
- Original fork target: `bet0x/valkey` branch `unstable`, commit `9b2284900efa42e205e421ed6307019da5b15497`.
- Rebased audit branch: `audit/bet0x-active-active-fix-rebased`, based on `valkey-io/valkey:unstable` commit `6c9d7fc263dd4dfe07460f7ed6de63295890b77a`.
- Backup branch before rebase: `audit/bet0x-active-active-fix-pre-rebase`.

The reviewed implementation adds active/active replication controls, `REPLICAOF ADD/REMOVE`, internal `RREPLAY`, `MVCCRESTORE`, MVCC key clocks, replay dedupe, peer replay queues, RDB AUX metadata, and INFO/ROLE telemetry.

## Current Result

The rebased branch builds and the focused active/active suites pass after local fixes. This pass adds the first productionization guardrails: an explicit command semantics matrix, debug-only access to `MVCCRESTORE` and `RREPLAYACK`, unlimited MVCC RDB clock persistence by default, a requirement that active/active mode keep AOF RDB preambles enabled, hardened ACK handling, fail-closed replay queue caps, and layered TLA+ specs for core replay and future typed merge semantics.

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
| `unit/rreplay` | 4 passed, 0 failed |
| `integration/replication-multimaster-aof` | 4 passed, 0 failed |
| `integration/replication-multimaster-rreplay` | 21 passed, 0 failed |
| `integration/replication-multimaster` | 14 passed, 0 failed |
| `integration/replication-multimaster-upstreams` | 12 passed, 0 failed |
| `integration/replication-multimaster-topologies` | 9 passed, 0 failed |

Formal/model checks:
- `audit/formal/MultiMaster-supported.cfg`: no TLC invariant violations; 5,510,617 states generated, 1,167,907 distinct states.
- `audit/formal/MultiMaster-unsupported.cfg`: no TLC invariant violations; 3,515 states generated, 925 distinct states.
- `audit/formal/CoreReplay.cfg`: no TLC invariant violations; 55,631 states generated, 5,905 distinct states.
- `audit/formal/TypeSemantics.cfg`: no TLC invariant violations; 924,305 states generated, 181,804 distinct states.
- `audit/formal/Persistence.cfg`: no TLC invariant violations; 6 states generated, 6 distinct states.
- Invariants checked: type safety, convergence after network quiescence, no own-origin in-flight messages, ACK monotonicity, no impossible ACK progress, and bounded replay queues.

Simulator:
- `audit/sim/mm_sim.py --runs 10000 --steps 150`: no convergence failures after draining the network.
- Simulator now models `SET`, `MSET`, single-key `DEL`, duplicate delivery, partitions/heal, restart with optional dedupe loss, own-origin drops, rejected `INCR`, rejected unsupported/partial commands, dedupe eviction with MVCC freshness fallback, and replay queue cap rejection.

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

### 5. Active/Active Could Be Combined With AOF Without Metadata Preambles

Bug found during follow-through: active/active metadata is persisted through RDB AUX fields. If a node is configured to use AOF without an RDB preamble, a restart can replay dataset mutations without the matching MVCC/replay metadata. That weakens stale replay rejection after restart.

Fix:
- `multi-master yes` now requires `aof-use-rdb-preamble yes`.
- `CONFIG SET aof-use-rdb-preamble no` is rejected while `multi-master` is enabled.
- `CONFIG SET appendonly yes` also refuses the unsafe combination if the preamble is disabled.
- Regression coverage asserts the unsafe preamble change is rejected in active/active mode.

### 6. The "Unlimited" MVCC RDB Default Persisted Zero Key Clocks

Bug found during AOF/RDB follow-through: `mvcc-rdb-clock-max-entries 0` was intended to mean unlimited, but the save path initialized the effective cap to `0`. With the production default, RDB/AOF-preamble saves could emit `mvcc-keys-count` without any `mvcc-key-N` entries.

Shortest repro shape:
1. Enable active/active and write key `k=seed`.
2. Save/restart with the default `mvcc-rdb-clock-max-entries 0`.
3. Replay an older serialized value with a low MVCC timestamp.
4. Without the per-key clock, the stale payload can overwrite the newer value.

Fix:
- The save path now treats `0` as `mvcc_count`, i.e. no cap.
- The RDB restart regression now uses a genuinely stale payload with a different value, so missing key-clock metadata fails visibly.

### 7. AOF Rewrite/Load Dropped Active/Active Metadata

Bug found during AOF testing: AOF rewrite called `rdbSaveRio(..., NULL)`, so the RDB preamble omitted active/active AUX metadata. AOF load then called `rdbLoadRio(..., NULL)`, so even present metadata would not be applied. In addition, local active/active writes were only MVCC-stamped when a primary link was connected, leaving disconnected writes untracked.

Fix:
- AOF rewrite now populates and writes active/active save-info metadata into RDB preambles.
- AOF load now reads and applies configured upstreams, runtime state, MVCC clocks, and RREPLAY dedupe state from the preamble before replaying the incremental AOF tail.
- Local active/active writes always enter the RREPLAY/MVCC stamping path, even when peers are absent or disconnected.
- Supported writes replayed from an incremental AOF tail are MVCC-stamped during AOF load when active/active is configured.
- Regression coverage restarts from an AOF RDB preamble and verifies stale `MVCCRESTORE` payloads are rejected for base-file data, post-rewrite incremental AOF tail data, multi-key `MSET`, and single-key `DEL` tombstones.

### 8. Replay ACKs Could Advance On Stale Or Impossible IDs

Bug found during ACK hardening: peer integer replies were treated as progress without validating that the ACK id was newer, within the sent range, and matched the first pending replay frame. A duplicate or impossible ACK could therefore move `replay_last_acked_id` or pop a pending frame that had not actually been acknowledged.

Fix:
- `upstreamRuntimeTrackReplayAck` now classifies ACKs as applied, stale, impossible, or out-of-order.
- Duplicate/stale ACK ids do not advance state.
- ACK ids greater than `replay_last_sent_id` are logged and ignored.
- Queue-backed peer links require the ACK to match the first pending replay id before draining the queue.
- `RREPLAYACK` is debug-gated and used by tests to inject stale and impossible ACK ids without exposing the control to normal clients.

### 9. Older Active/Active AOF Tails Could Load Now-Rejected Commands

Bug found during persistence coverage: AOF loading calls command implementations directly and bypasses the normal client command gate. An older active/active AOF tail containing a command that is now rejected, for example `HSET`, could mutate the dataset during restart before the active/active allowlist was consulted.

Fix:
- AOF load now checks active/active write commands before execution.
- Supported durable commands (`SET`, `MSET`, single-key `DEL`, and internal `MVCCRESTORE`) still load.
- Unsupported active/active writes fail the load before mutation.
- Regression coverage constructs an AOF tail with `HSET` and asserts the server exits instead of loading it.

### 10. Queue Overflow Full Sync Could Overwrite Concurrent Local Writes

Bug found by the simulator during this pass. The earlier queue overflow behavior dropped pending frames and asked the peer to perform an ordinary full sync from the sender. In active/active mode, ordinary full sync is not a merge. It can replace a peer's dataset and wipe a write that was accepted locally on that peer while the replay link was partitioned.

Shortest simulator trace shape:
1. A and B are partitioned.
2. A accepts a local write while B's queue toward A later overflows.
3. B requests/forces A to full-sync from B.
4. A's local write is overwritten because the full sync copies B's dataset rather than applying MVCC merge semantics.

Fix:
- Local active/active writes now fail before mutation when any replay queue is at its configured cap or a runtime is already marked as requiring repair.
- The automatic peer `REPLICAOF` full-sync request after overflow is disabled and replaced with a warning that manual repair is required.
- The topology regression now fills the queue to the cap, verifies the next write is rejected before mutation, reconnects the peer, drains the queued frames, and verifies writes resume only after the queue is clear.
- The simulator's deterministic queue-cap scenario now shows the capped write rejected on both nodes, and the 10,000-run randomized search no longer reproduces the overwrite counterexample.

## Open Risks

### MVCC Clock Persistence Cap

`mvcc-rdb-clock-max-entries` can cap persisted key clocks if configured to a positive value. The production default is now `0` (unlimited), and positive caps in `multi-master` mode require `active-replica-debug-commands yes`. The cap remains a debug/operational escape hatch and still degrades stale-write protection when deliberately enabled.

### Interrupted AOF Rewrite And Restart Semantics

The new AOF regression covers supported `SET` writes in both the RDB base file and the incremental AOF tail, plus multi-key `MSET`, single-key `DEL` tombstones, and older AOF tails containing now-rejected writes. Broader AOF fault tests are still needed for interrupted rewrites and torn persistence around OS/process failure boundaries.

### Queue Repair After Cap Exhaustion

Queue caps now fail closed instead of silently dropping frames or forcing an unsafe ordinary full sync. That avoids the data-loss counterexample, but it leaves availability and operator workflow open: once a runtime is marked repair-required by an unexpected overflow path, active/active writes are rejected until manual repair or a future merge-aware resync mechanism exists.

### Dedupe Bound

`RREPLAY_DEDUP_MAX_ENTRIES` is fixed at 10,000 entries. This bounds memory but means old duplicate frames can be accepted again after eviction. A new regression and simulator scenario verify that MVCC freshness prevents value rollback for stale `SET` after dedupe eviction, but this remains bounded idempotence, not permanent dedupe.

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
./runtest --single integration/replication-multimaster-aof
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/MultiMaster-supported.cfg audit/formal/MultiMaster.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/MultiMaster-unsupported.cfg audit/formal/MultiMaster.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/CoreReplay.cfg audit/formal/CoreReplay.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/TypeSemantics.cfg audit/formal/TypeSemantics.tla
java -jar audit/formal/tla2tools.jar -deadlock -config audit/formal/Persistence.cfg audit/formal/Persistence.tla
audit/sim/mm_sim.py --runs 10000 --steps 150
```
