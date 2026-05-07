------------------------------ MODULE CoreReplay ------------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, MaxId, QueueCap

VARIABLES nextId, seen, net, pending, linkUp, fullsyncNeeded, lastAck

vars == <<nextId, seen, net, pending, linkUp, fullsyncNeeded, lastAck>>

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
    /\ lastAck = [p \in Pair |-> 0]

Peers(n) == Nodes \ {n}

FanoutAvailable(n) ==
    \A d \in Peers(n):
        /\ ~fullsyncNeeded[<<n, d>>]
        /\ Cardinality(pending[<<n, d>>]) < QueueCap

QueueOrSend(src, dst, f) ==
    IF linkUp[<<src, dst>>]
         THEN /\ net' = net \cup {[src |-> src, dst |-> dst, frame |-> f]}
              /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \cup {f}]
              /\ fullsyncNeeded' = fullsyncNeeded
         ELSE /\ net' = net
              /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \cup {f}]
              /\ fullsyncNeeded' = fullsyncNeeded

LocalWrite ==
    \E n \in Nodes:
        /\ nextId[n] <= MaxId
        /\ FanoutAvailable(n)
        /\ \E d \in Peers(n):
            LET f == [origin |-> n, id |-> nextId[n]] IN
            /\ QueueOrSend(n, d, f)
            /\ nextId' = [nextId EXCEPT ![n] = @ + 1]
            /\ seen' = seen
            /\ linkUp' = linkUp
            /\ lastAck' = lastAck

RejectedWrite ==
    \E n \in Nodes:
        /\ ~FanoutAvailable(n)
        /\ UNCHANGED vars

Deliver ==
    \E m \in net:
        LET d == m.dst
            k == FrameKey(m.frame) IN
        /\ net' = net \ {m}
        /\ seen' = [seen EXCEPT ![d] = @ \cup {k}]
        /\ nextId' = [nextId EXCEPT ![d] = IF @ <= m.frame.id THEN m.frame.id + 1 ELSE @]
        /\ UNCHANGED <<pending, linkUp, fullsyncNeeded, lastAck>>

Ack ==
    \E src \in Nodes:
    \E dst \in Peers(src):
    \E f \in pending[<<src, dst>>]:
        /\ FrameKey(f) \in seen[dst]
        /\ f.id > lastAck[<<src, dst>>]
        /\ f.id < nextId[src]
        /\ pending' = [pending EXCEPT ![<<src, dst>>] = @ \ {f}]
        /\ lastAck' = [lastAck EXCEPT ![<<src, dst>>] = f.id]
        /\ UNCHANGED <<nextId, seen, net, linkUp, fullsyncNeeded>>

StaleAck ==
    \E src \in Nodes:
    \E dst \in Peers(src):
    \E id \in 1..MaxId:
        /\ id <= lastAck[<<src, dst>>]
        /\ UNCHANGED vars

ImpossibleAck ==
    \E src \in Nodes:
    \E dst \in Peers(src):
    \E id \in 1..MaxId:
        /\ id >= nextId[src]
        /\ UNCHANGED vars

Disconnect ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ linkUp[<<src, dst>>]
        /\ linkUp' = [linkUp EXCEPT ![<<src, dst>>] = FALSE]
        /\ UNCHANGED <<nextId, seen, net, pending, fullsyncNeeded, lastAck>>

Reconnect ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ ~linkUp[<<src, dst>>]
        /\ linkUp' = [linkUp EXCEPT ![<<src, dst>>] = TRUE]
        /\ net' = net \cup {[src |-> src, dst |-> dst, frame |-> f] : f \in pending[<<src, dst>>]}
        /\ UNCHANGED <<nextId, seen, pending, fullsyncNeeded, lastAck>>

ManualRepair ==
    \E src \in Nodes:
    \E dst \in Peers(src):
        /\ fullsyncNeeded[<<src, dst>>]
        /\ pending' = [pending EXCEPT ![<<src, dst>>] = {}]
        /\ fullsyncNeeded' = [fullsyncNeeded EXCEPT ![<<src, dst>>] = FALSE]
        /\ UNCHANGED <<nextId, seen, net, linkUp, lastAck>>

Duplicate ==
    \E m \in net:
        /\ net' = net \cup {m}
        /\ UNCHANGED <<nextId, seen, pending, linkUp, fullsyncNeeded, lastAck>>

Next == LocalWrite \/ RejectedWrite \/ Deliver \/ Ack \/ StaleAck \/ ImpossibleAck \/ Disconnect \/ Reconnect \/ ManualRepair \/ Duplicate

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ nextId \in [Nodes -> 1..(MaxId + 1)]
    /\ seen \in [Nodes -> SUBSET (Nodes \X (1..MaxId))]
    /\ net \subseteq Msg
    /\ pending \in [Pair -> SUBSET Frame]
    /\ linkUp \in [Pair -> BOOLEAN]
    /\ fullsyncNeeded \in [Pair -> BOOLEAN]
    /\ lastAck \in [Pair -> 0..MaxId]

NoOwnOriginDeliverable ==
    \A m \in net: m.src # m.dst /\ m.frame.origin # m.dst

QueueBounded ==
    \A src \in Nodes:
    \A dst \in Peers(src):
        Cardinality(pending[<<src, dst>>]) <= QueueCap

RepairDoesNotAdvanceAck ==
    \A src \in Nodes:
    \A dst \in Peers(src):
        fullsyncNeeded[<<src, dst>>] => lastAck[<<src, dst>>] < nextId[src]

AckNeverExceedsSent ==
    \A src \in Nodes:
    \A dst \in Peers(src):
        lastAck[<<src, dst>>] < nextId[src]

=============================================================================
