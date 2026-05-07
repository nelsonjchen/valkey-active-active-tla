#!/usr/bin/env python3
"""Small discrete-event simulator for bet0x Valkey multimaster audit.

The simulator mirrors the branch's command-level RREPLAY/MVCC shape:
- local writes are applied immediately and forwarded as replay frames;
- incoming frames use per-key LWW with deterministic tie-breaks;
- seen replay ids make duplicate delivery idempotent;
- unsupported, lossy RMW, and partial collection operations are rejected before
  local mutation.

It is deliberately not a Redis emulator. Its job is to search protocol-level
traces and expose where convergence differs from stronger user expectations.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import argparse
import json
import random
from typing import Dict, List, Tuple


Key = str
Value = object


@dataclass(frozen=True)
class Meta:
    ts: int
    origin: str
    rid: int


ZERO = Meta(0, "", 0)


@dataclass(frozen=True)
class Frame:
    origin: str
    rid: int
    ts: int
    op: str
    args: Tuple[object, ...]


@dataclass
class Node:
    name: str
    clock: int = 0
    seq: int = 0
    data: Dict[Key, Value] = field(default_factory=dict)
    meta: Dict[Key, Meta] = field(default_factory=dict)
    seen: set[Tuple[str, int]] = field(default_factory=set)


class Sim:
    def __init__(self, nodes: Tuple[str, ...] = ("A", "B", "C"), seed: int = 0):
        self.rng = random.Random(seed)
        self.nodes = {name: Node(name) for name in nodes}
        self.net: List[Tuple[str, Frame]] = []
        self.history: List[str] = []

    def better(self, incoming: Meta, current: Meta) -> bool:
        return (incoming.ts, incoming.origin, incoming.rid) > (current.ts, current.origin, current.rid)

    def stamp(self, n: Node) -> Meta:
        n.clock += 1
        n.seq += 1
        return Meta(n.clock, n.name, n.seq)

    def apply_abs(self, n: Node, key: Key, value: Value, meta: Meta) -> bool:
        current = n.meta.get(key, ZERO)
        if self.better(meta, current):
            n.data[key] = value
            n.meta[key] = meta
            n.clock = max(n.clock, meta.ts)
            return True
        n.clock = max(n.clock, meta.ts)
        return False

    def apply_del(self, n: Node, key: Key, meta: Meta) -> bool:
        current = n.meta.get(key, ZERO)
        if self.better(meta, current):
            n.data.pop(key, None)
            n.meta[key] = meta
            n.clock = max(n.clock, meta.ts)
            return True
        n.clock = max(n.clock, meta.ts)
        return False

    def fanout(self, src: str, frame: Frame) -> None:
        for dst in self.nodes:
            if dst != src:
                self.net.append((dst, frame))

    def local_set(self, src: str, key: Key, value: Value) -> None:
        n = self.nodes[src]
        meta = self.stamp(n)
        self.apply_abs(n, key, value, meta)
        frame = Frame(src, meta.rid, meta.ts, "SET", (key, value))
        self.fanout(src, frame)
        self.history.append(f"{src}: SET {key}={value} ts={meta.ts}/{meta.rid}")

    def local_mset(self, src: str, items: Dict[Key, Value]) -> None:
        n = self.nodes[src]
        meta = self.stamp(n)
        for key, value in items.items():
            self.apply_abs(n, key, value, meta)
        frame = Frame(src, meta.rid, meta.ts, "MSET", tuple(items.items()))
        self.fanout(src, frame)
        self.history.append(f"{src}: MSET {items} ts={meta.ts}/{meta.rid}")

    def local_del(self, src: str, key: Key) -> None:
        n = self.nodes[src]
        meta = self.stamp(n)
        self.apply_del(n, key, meta)
        frame = Frame(src, meta.rid, meta.ts, "DEL", (key,))
        self.fanout(src, frame)
        self.history.append(f"{src}: DEL {key} ts={meta.ts}/{meta.rid}")

    def local_incr(self, src: str, key: Key, amount: int = 1) -> None:
        self.history.append(f"{src}: INCR {key} rejected before local mutation")

    def unsupported_local(self, src: str, key: Key, value: Value, op: str = "XADD") -> None:
        self.history.append(f"{src}: unsupported {op} {key}={value} rejected before local mutation")

    def deliver_one(self, index: int | None = None) -> None:
        if not self.net:
            return
        if index is None:
            index = self.rng.randrange(len(self.net))
        dst, frame = self.net.pop(index)
        n = self.nodes[dst]
        dedupe = (frame.origin, frame.rid)
        if dedupe in n.seen:
            self.history.append(f"deliver duplicate {frame.origin}/{frame.rid} to {dst}: ignored")
            return
        n.seen.add(dedupe)
        if frame.origin == dst:
            self.history.append(f"deliver own-origin {frame.origin}/{frame.rid} to {dst}: ignored")
            return

        meta = Meta(frame.ts, frame.origin, frame.rid)
        if frame.op == "SET":
            key, value = frame.args
            changed = self.apply_abs(n, key, value, meta)
            self.history.append(f"deliver SET {key}={value} {frame.origin}/{frame.rid} to {dst}: {'apply' if changed else 'stale'}")
        elif frame.op == "DEL":
            (key,) = frame.args
            changed = self.apply_del(n, key, meta)
            self.history.append(f"deliver DEL {key} {frame.origin}/{frame.rid} to {dst}: {'apply' if changed else 'stale'}")
        elif frame.op == "MSET":
            applied = []
            for key, value in frame.args:
                if self.apply_abs(n, key, value, meta):
                    applied.append(key)
            self.history.append(f"deliver MSET {frame.origin}/{frame.rid} to {dst}: applied={applied}")

    def duplicate_random_frame(self) -> None:
        if not self.net:
            return
        self.net.append(self.rng.choice(self.net))
        self.history.append("duplicated one in-flight frame")

    def drain(self) -> None:
        while self.net:
            self.deliver_one()

    def values_by_node(self, key: Key) -> Dict[str, Value]:
        return {name: node.data.get(key) for name, node in self.nodes.items()}

    def converged(self) -> bool:
        keys = set()
        for node in self.nodes.values():
            keys.update(node.data)
        for key in keys:
            vals = list(self.values_by_node(key).values())
            if any(v != vals[0] for v in vals):
                return False
        return True


def rmw_rejection() -> dict:
    sim = Sim(nodes=("A", "B"), seed=1)
    sim.local_incr("A", "ctr")
    sim.local_incr("B", "ctr")
    sim.drain()
    return {
        "name": "concurrent INCR attempts are rejected before local mutation",
        "values": sim.values_by_node("ctr"),
        "converged": sim.converged(),
        "history": sim.history,
    }


def unsupported_counterexample() -> dict:
    sim = Sim(nodes=("A", "B"), seed=2)
    sim.unsupported_local("A", "stream", "entry-1")
    sim.unsupported_local("B", "hash", "field=value", op="HSET")
    sim.unsupported_local("A", "zset", "member=1", op="ZADD")
    sim.unsupported_local("B", "rename-src", "rename-dst", op="RENAME")
    sim.drain()
    return {
        "name": "unsupported and partial commands are rejected before local mutation",
        "values": sim.values_by_node("stream"),
        "converged": sim.converged(),
        "history": sim.history,
    }


def randomized_supported(seed: int, runs: int, steps: int) -> dict:
    failures = []
    for run in range(runs):
        sim = Sim(seed=seed + run)
        for _ in range(steps):
            op = sim.rng.choice(["SET", "MSET", "DEL", "INCR", "DELIVER", "DUP"])
            node = sim.rng.choice(list(sim.nodes))
            if op == "SET":
                sim.local_set(node, sim.rng.choice(["x", "y"]), sim.rng.choice(["v1", "v2", "v3"]))
            elif op == "MSET":
                sim.local_mset(node, {"x": sim.rng.choice(["v1", "v2"]), "y": sim.rng.choice(["v1", "v2"])})
            elif op == "DEL":
                sim.local_del(node, sim.rng.choice(["x", "y"]))
            elif op == "INCR":
                sim.local_incr(node, "ctr")
            elif op == "DUP":
                sim.duplicate_random_frame()
            else:
                sim.deliver_one()
        sim.drain()
        if not sim.converged():
            failures.append({"run": run, "history": sim.history, "state": {k: n.data for k, n in sim.nodes.items()}})
            break
    return {
        "name": "randomized supported-command convergence",
        "seed": seed,
        "runs": runs,
        "steps_per_run": steps,
        "failures": failures,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=20260506)
    parser.add_argument("--runs", type=int, default=2000)
    parser.add_argument("--steps", type=int, default=80)
    args = parser.parse_args()

    results = [
        randomized_supported(args.seed, args.runs, args.steps),
        rmw_rejection(),
        unsupported_counterexample(),
    ]
    print(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
