# Valkey Active/Active TLA+ Audit Artifacts

This repository contains the standalone formal and simulation artifacts from an audit of the experimental `bet0x/valkey` active/active replication fork.

Reviewed Valkey branches:
- Original implementation: `bet0x/valkey` `unstable` at `9b2284900efa42e205e421ed6307019da5b15497`
- Rebased audit branch: `nelsonjchen/valkey` `audit/bet0x-active-active-fix-rebased`

## Contents

- `formal/MultiMaster.tla`: small TLA+ model of supported active/active replay semantics.
- `formal/MultiMaster-supported.cfg`: TLC config for supported `SET`, `MSET`, and single-key `DEL` behavior.
- `formal/MultiMaster-unsupported.cfg`: TLC config where unsupported/RMW/partial writes are rejected before mutation.
- `formal/CoreReplay.tla`: TLA+ model of replay ids, dedupe, disconnect/reconnect, ACK, pending queues, and fullsync.
- `formal/TypeSemantics.tla`: TLA+ target model for LWW registers, counters, hash fields, and OR-set style metadata.
- `sim/mm_sim.py`: randomized discrete-event simulator for larger replay/dedupe traces.
- `logs/`: selected TLC and simulator outputs.
- `COMMAND_MATRIX.md`: production command semantics gate.
- `FINDINGS.md`: maintainer-facing report with fixed bugs, open risks, and reproduction notes.

## Run

Download `tla2tools.jar` from the TLA+ project, then run:

```bash
java -jar tla2tools.jar -deadlock -config formal/MultiMaster-supported.cfg formal/MultiMaster.tla
java -jar tla2tools.jar -deadlock -config formal/MultiMaster-unsupported.cfg formal/MultiMaster.tla
java -jar tla2tools.jar -deadlock -config formal/CoreReplay.cfg formal/CoreReplay.tla
java -jar tla2tools.jar -deadlock -config formal/TypeSemantics.cfg formal/TypeSemantics.tla
sim/mm_sim.py --runs 2000 --steps 80
```

The checked model is intentionally small. It is evidence for the narrowed protocol shape, not a proof of the full Valkey implementation.
