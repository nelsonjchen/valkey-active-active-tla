----------------------------- MODULE MultiMaster -----------------------------
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Nodes, Keys, Values, None, MaxTs, AllowUnsupported

VARIABLES store, seen, net, nextId

vars == <<store, seen, net, nextId>>

Frame ==
    [origin: Nodes, id: 1..MaxTs, key: Keys, value: Values \cup {None}, ts: 1..MaxTs]

Msg == [dst: Nodes, frame: Frame]

FrameKey(f) == <<f.origin, f.id>>

\* This model is intentionally small and uses two node names in the checked
\* configs. The branch code uses strcmp("<uuid>:<id>") for equal timestamps;
\* Rank gives the model a deterministic equivalent.
Rank(n) ==
    IF n = "A" THEN 1
    ELSE IF n = "B" THEN 2
    ELSE 3

Init ==
    /\ store = [n \in Nodes |->
        [k \in Keys |-> [value |-> None, ts |-> 0, origin |-> None, id |-> 0]]]
    /\ seen = [n \in Nodes |-> {}]
    /\ net = {}
    /\ nextId = [n \in Nodes |-> 1]

Fresh(f, cur) ==
    \/ f.ts > cur.ts
    \/ /\ f.ts = cur.ts
       /\ \/ Rank(f.origin) > Rank(cur.origin)
          \/ /\ f.origin = cur.origin
             /\ f.id > cur.id

ApplyFrame(d, f) ==
    LET cur == store[d][f.key] IN
    IF Fresh(f, cur)
    THEN [store EXCEPT ![d][f.key] =
        [value |-> f.value, ts |-> f.ts, origin |-> f.origin, id |-> f.id]]
    ELSE store

LocalWrite ==
    \E n \in Nodes, k \in Keys, v \in Values:
        /\ nextId[n] <= MaxTs
        /\ LET f == [origin |-> n, id |-> nextId[n], key |-> k,
                     value |-> v, ts |-> nextId[n]] IN
           /\ store' = [store EXCEPT ![n][k] =
                [value |-> v, ts |-> f.ts, origin |-> n, id |-> f.id]]
           /\ seen' = seen
           /\ net' = net \cup {[dst |-> d, frame |-> f] : d \in Nodes \ {n}}
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

LocalDelete ==
    \E n \in Nodes, k \in Keys:
        /\ nextId[n] <= MaxTs
        /\ LET f == [origin |-> n, id |-> nextId[n], key |-> k,
                     value |-> None, ts |-> nextId[n]] IN
           /\ store' = [store EXCEPT ![n][k] =
                [value |-> None, ts |-> f.ts, origin |-> n, id |-> f.id]]
           /\ seen' = seen
           /\ net' = net \cup {[dst |-> d, frame |-> f] : d \in Nodes \ {n}}
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

Deliver ==
    \E msg \in net:
        LET d == msg.dst
            f == msg.frame
            key == FrameKey(f) IN
        /\ net' = net \ {msg}
        /\ seen' = [seen EXCEPT ![d] = @ \cup {key}]
        /\ store' =
            IF f.origin = d \/ key \in seen[d]
            THEN store
            ELSE ApplyFrame(d, f)
        /\ nextId' = [nextId EXCEPT ![d] =
            IF @ <= f.ts THEN f.ts + 1 ELSE @]

\* Models unsupported or lossy RMW local write attempts after the fixes:
\* processCommand checks RREPLAY representability before execution, so the
\* command is rejected and the dataset/clock/network are unchanged.
UnsupportedOrRMWWriteRejected ==
    /\ AllowUnsupported
    /\ \E n \in Nodes, k \in Keys, v \in Values: nextId[n] <= MaxTs
    /\ UNCHANGED vars

Next == LocalWrite \/ LocalDelete \/ Deliver \/ UnsupportedOrRMWWriteRejected

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ store \in [Nodes -> [Keys -> [value: Values \cup {None},
                                     ts: 0..MaxTs,
                                     origin: Nodes \cup {None},
                                     id: 0..MaxTs]]]
    /\ seen \in [Nodes -> SUBSET (Nodes \X (1..MaxTs))]
    /\ net \subseteq Msg
    /\ nextId \in [Nodes -> 1..(MaxTs + 1)]

QuiescentConverged ==
    net # {} \/
    \A n \in Nodes, m \in Nodes, k \in Keys:
        store[n][k].value = store[m][k].value

NoOwnOriginMessages ==
    \A msg \in net: msg.dst # msg.frame.origin

=============================================================================
