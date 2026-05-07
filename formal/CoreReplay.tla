------------------------------ MODULE CoreReplay ------------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, MaxId, QueueCap

VARIABLES nextId, seen, net, pending, linkUp, fullsyncNeeded

vars == <<nextId, seen, net, pending, linkUp, fullsyncNeeded>>

Frame == [origin: Nodes, id: 1..MaxId]
Msg == [src: Nodes, dst: Nodes, frame: Frame]
Pair == Nodes \X Nodes

FrameKey(f) == <<f.origin, f.id>>

Init ==
    /\ nextId = [n \in Nodes |-> 1]
    /\ seen = [n \in Nodes |-> {}]
    /\ net = {}
    /\ pending = [p \in Pair |-> {}]
    /\ linkUp = [p \in Pair |-> TRUE]
    /\ fullsyncNeeded = [p \in Pair |-> FALSE]

Peers(n) == Nodes \ {n}

QueueOrSend(src, dst, f) ==
    IF Cardinality(pending[<<src, dst>>]) >= QueueCap
    THEN /\ net' = net
         /\ pending' = [pending EXCEPT ![<<src, dst>>] = {}]
         /\ fullsyncNeeded' = [fullsyncNeeded EXCEPT ![<<src, dst>>] = TRUE]
    ELSE IF linkUp[<<src, dst>>]
         THEN /\ net' = net \cup {[src |-> src, dst |-> dst, frame |-> f]}
              /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \cup {f}]
              /\ fullsyncNeeded' = fullsyncNeeded
         ELSE /\ net' = net
              /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \cup {f}]
              /\ fullsyncNeeded' = fullsyncNeeded

LocalWrite ==
    \E n \in Nodes:
        /\ nextId[n] <= MaxId
        /\ \E d \in Peers(n):
            LET f == [origin |-> n, id |-> nextId[n]] IN
            /\ QueueOrSend(n, d, f)
            /\ nextId' = [nextId EXCEPT ![n] = @ + 1]
            /\ seen' = seen
            /\ linkUp' = linkUp

Deliver ==
    \E m \in net:
        LET d == m.dst
            k == FrameKey(m.frame) IN
        /\ net' = net \ {m}
        /\ seen' = [seen EXCEPT ![d] = @ \cup {k}]
        /\ nextId' = [nextId EXCEPT ![d] = IF @ <= m.frame.id THEN m.frame.id + 1 ELSE @]
        /\ UNCHANGED <<pending, linkUp, fullsyncNeeded>>

Ack ==
    \E src \in Nodes:
    \E dst \in Peers(src):
    \E f \in pending[<<src, dst>>]:
        /\ FrameKey(f) \in seen[dst]
        /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \ {f}]
        /\ UNCHANGED <<nextId, seen, net, linkUp, fullsyncNeeded>>

Disconnect ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ linkUp[<<src, dst>>]
        /\ linkUp' = [linkUp EXCEPT ![<<src, dst>>] = FALSE]
        /\ UNCHANGED <<nextId, seen, net, pending, fullsyncNeeded>>

Reconnect ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ ~linkUp[<<src, dst>>]
        /\ linkUp' = [linkUp EXCEPT ![<<src, dst>>] = TRUE]
        /\ net' = net \cup {[src |-> src, dst |-> dst, frame |-> f] : f \in pending[<<src, dst>>]}
        /\ UNCHANGED <<nextId, seen, pending, fullsyncNeeded>>

FullSync ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ fullsyncNeeded[<<src, dst>>]
        /\ pending' = [pending EXCEPT ![<<src, dst>>] = {}]
        /\ fullsyncNeeded' = [fullsyncNeeded EXCEPT ![<<src, dst>>] = FALSE]
        /\ seen' = [seen EXCEPT ![dst] = @ \cup {FrameKey(f) : f \in pending[<<src, dst>>]}]
        /\ UNCHANGED <<nextId, net, linkUp>>

Duplicate ==
    \E m \in net:
        /\ net' = net \cup {m}
        /\ UNCHANGED <<nextId, seen, pending, linkUp, fullsyncNeeded>>

Next == LocalWrite \/ Deliver \/ Ack \/ Disconnect \/ Reconnect \/ FullSync \/ Duplicate

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ nextId \in [Nodes -> 1..(MaxId + 1)]
    /\ seen \in [Nodes -> SUBSET (Nodes \X (1..MaxId))]
    /\ net \subseteq Msg
    /\ pending \in [Pair -> SUBSET Frame]
    /\ linkUp \in [Pair -> BOOLEAN]
    /\ fullsyncNeeded \in [Pair -> BOOLEAN]

NoOwnOriginDeliverable ==
    \A m \in net: m.src # m.dst /\ m.frame.origin # m.dst

QueueBoundedOrFullSync ==
    \A src \in Nodes:
    \A dst \in Peers(src):
        Cardinality(pending[<<src, dst>>]) <= QueueCap \/ fullsyncNeeded[<<src, dst>>]

=============================================================================
