# Active/Active Command Semantics Matrix

This matrix is the production gate for active/active mode. A command is enabled only when its state is `supported` and matching tests/model coverage exist.

| State | Meaning |
| --- | --- |
| `supported` | Implemented with explicit convergence semantics and enabled in active/active mode. |
| `supported with CRDT metadata` | Intended to preserve user intent, but requires typed metadata before enabling. |
| `single-writer/future` | Needs single-writer routing or a command-specific design before enabling. |
| `rejected` | Unsafe or out of scope for the private fork until specified. |

## Current Supported Surface

| Command | State | Semantics |
| --- | --- | --- |
| `SET` | `supported` | Key-level LWW register. Relative TTL options are rejected. |
| `MSET` | `supported` | Per-key LWW registers; stale keys are filtered independently during replay. |
| `DEL key` | `supported` | Single-key LWW tombstone. |
| `MVCCRESTORE` | `supported` | Internal/debug restore with explicit MVCC timestamp; normal clients need `active-replica-debug-commands yes`. |

## Requires Typed CRDT Metadata

| Command family | State | Needed semantics |
| --- | --- | --- |
| `INCR`, `DECR`, `INCRBY`, `INCRBYFLOAT` | `supported with CRDT metadata` | Per-origin PN-counter or equivalent delta counter. |
| `HSET`, `HDEL`, `HMSET`-style updates | `supported with CRDT metadata` | Hash OR-map with per-field registers/tombstones. |
| `HINCRBY`, `HINCRBYFLOAT` | `supported with CRDT metadata` | Hash field counter metadata. |
| `SADD`, `SREM` | `supported with CRDT metadata` | OR-set add/remove dots and tombstones. |
| `ZADD`, `ZREM` | `supported with CRDT metadata` | Per-member score register and remove metadata. |
| `ZINCRBY` | `supported with CRDT metadata` | Per-member score counter/delta semantics. |
| `EXPIRE`, `PEXPIRE`, `EXPIREAT`, `PEXPIREAT`, `PERSIST` | `supported with CRDT metadata` | Absolute expiry register with conflict rules against value writes. |

## Future Or Rejected

| Command family | State | Reason |
| --- | --- | --- |
| Multi-key `DEL`, `RENAME`, `RENAMENX`, `COPY`, migration-style moves | `single-writer/future` | Atomic multi-key intent needs transaction/routing semantics. |
| `MULTI`/`EXEC`/`WATCH` | `single-writer/future` | Cross-command atomicity is not modeled. |
| `EVAL`, `EVALSHA`, functions, modules | `single-writer/future` | Arbitrary code cannot be safely merged generically. |
| Lists and blocking list operations | `single-writer/future` | List ordering under concurrency needs a sequence CRDT or routing. |
| Streams and consumer groups | `single-writer/future` | Stream IDs, trimming, PEL, and consumer state need a dedicated design. |
| Admin/global commands, pubsub, all-DB commands | `rejected` | Not key-local active/active data operations. |
