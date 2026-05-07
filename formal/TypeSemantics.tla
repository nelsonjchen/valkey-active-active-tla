---------------------------- MODULE TypeSemantics ----------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Nodes, Values, Fields, Elements, None, MaxId

VARIABLES nextId, reg, ctr, hmap, adds, rems, net

vars == <<nextId, reg, ctr, hmap, adds, rems, net>>

Ops == {"SET", "INC", "HSET", "SADD", "SREM"}
Dot == Nodes \X (1..MaxId)
Reg == [value: Values \cup {None}, ts: 0..MaxId, origin: Nodes \cup {None}, id: 0..MaxId]
Frame == [op: Ops, origin: Nodes, id: 1..MaxId, value: Values \cup {None}, field: Fields \cup {None}, elem: Elements \cup {None}, dots: SUBSET Dot]
Msg == [dst: Nodes, frame: Frame]

Rank(n) ==
    IF n = "A" THEN 1
    ELSE IF n = "B" THEN 2
    ELSE 3

Better(f, cur) ==
    \/ f.id > cur.ts
    \/ /\ f.id = cur.ts
       /\ Rank(f.origin) > Rank(cur.origin)

Visible(sadds, srems, e) == sadds[e] \ srems[e]

ApplyFrame(n, f) ==
    IF f.op = "SET" THEN
        /\ reg' = IF Better(f, reg[n])
                  THEN [reg EXCEPT ![n] = [value |-> f.value, ts |-> f.id, origin |-> f.origin, id |-> f.id]]
                  ELSE reg
        /\ UNCHANGED <<ctr, hmap, adds, rems>>
    ELSE IF f.op = "INC" THEN
        /\ ctr' = [ctr EXCEPT ![n][f.origin] = IF @ < f.id THEN f.id ELSE @]
        /\ UNCHANGED <<reg, hmap, adds, rems>>
    ELSE IF f.op = "HSET" THEN
        /\ hmap' = IF Better(f, hmap[n][f.field])
                   THEN [hmap EXCEPT ![n][f.field] = [value |-> f.value, ts |-> f.id, origin |-> f.origin, id |-> f.id]]
                   ELSE hmap
        /\ UNCHANGED <<reg, ctr, adds, rems>>
    ELSE IF f.op = "SADD" THEN
        /\ adds' = [adds EXCEPT ![n][f.elem] = @ \cup {<<f.origin, f.id>>}]
        /\ UNCHANGED <<reg, ctr, hmap, rems>>
    ELSE
        /\ rems' = [rems EXCEPT ![n][f.elem] = @ \cup f.dots]
        /\ UNCHANGED <<reg, ctr, hmap, adds>>

Fanout(n, f) == {[dst |-> d, frame |-> f] : d \in Nodes \ {n}}

Init ==
    /\ nextId = [n \in Nodes |-> 1]
    /\ reg = [n \in Nodes |-> [value |-> None, ts |-> 0, origin |-> None, id |-> 0]]
    /\ ctr = [n \in Nodes |-> [o \in Nodes |-> 0]]
    /\ hmap = [n \in Nodes |-> [f \in Fields |-> [value |-> None, ts |-> 0, origin |-> None, id |-> 0]]]
    /\ adds = [n \in Nodes |-> [e \in Elements |-> {}]]
    /\ rems = [n \in Nodes |-> [e \in Elements |-> {}]]
    /\ net = {}

LocalSet ==
    \E n \in Nodes, v \in Values:
        /\ nextId[n] <= MaxId
        /\ LET f == [op |-> "SET", origin |-> n, id |-> nextId[n], value |-> v, field |-> None, elem |-> None, dots |-> {}] IN
           /\ ApplyFrame(n, f)
           /\ net' = net \cup Fanout(n, f)
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

LocalInc ==
    \E n \in Nodes:
        /\ nextId[n] <= MaxId
        /\ LET f == [op |-> "INC", origin |-> n, id |-> nextId[n], value |-> None, field |-> None, elem |-> None, dots |-> {}] IN
           /\ ApplyFrame(n, f)
           /\ net' = net \cup Fanout(n, f)
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

LocalHSet ==
    \E n \in Nodes, fld \in Fields, v \in Values:
        /\ nextId[n] <= MaxId
        /\ LET f == [op |-> "HSET", origin |-> n, id |-> nextId[n], value |-> v, field |-> fld, elem |-> None, dots |-> {}] IN
           /\ ApplyFrame(n, f)
           /\ net' = net \cup Fanout(n, f)
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

LocalSAdd ==
    \E n \in Nodes, e \in Elements:
        /\ nextId[n] <= MaxId
        /\ LET f == [op |-> "SADD", origin |-> n, id |-> nextId[n], value |-> None, field |-> None, elem |-> e, dots |-> {}] IN
           /\ ApplyFrame(n, f)
           /\ net' = net \cup Fanout(n, f)
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

LocalSRem ==
    \E n \in Nodes, e \in Elements:
        /\ nextId[n] <= MaxId
        /\ LET f == [op |-> "SREM", origin |-> n, id |-> nextId[n], value |-> None, field |-> None, elem |-> e, dots |-> Visible(adds[n], rems[n], e)] IN
           /\ ApplyFrame(n, f)
           /\ net' = net \cup Fanout(n, f)
           /\ nextId' = [nextId EXCEPT ![n] = @ + 1]

Deliver ==
    \E m \in net:
        /\ net' = net \ {m}
        /\ ApplyFrame(m.dst, m.frame)
        /\ nextId' = [nextId EXCEPT ![m.dst] = IF @ <= m.frame.id THEN m.frame.id + 1 ELSE @]

Duplicate ==
    \E m \in net:
        /\ net' = net \cup {m}
        /\ UNCHANGED <<nextId, reg, ctr, hmap, adds, rems>>

Next == LocalSet \/ LocalInc \/ LocalHSet \/ LocalSAdd \/ LocalSRem \/ Deliver \/ Duplicate

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ nextId \in [Nodes -> 1..(MaxId + 1)]
    /\ reg \in [Nodes -> Reg]
    /\ ctr \in [Nodes -> [Nodes -> 0..MaxId]]
    /\ hmap \in [Nodes -> [Fields -> Reg]]
    /\ adds \in [Nodes -> [Elements -> SUBSET Dot]]
    /\ rems \in [Nodes -> [Elements -> SUBSET Dot]]
    /\ net \subseteq Msg

QuiescentConverged ==
    net # {} \/
    /\ \A a \in Nodes, b \in Nodes: reg[a] = reg[b]
    /\ \A a \in Nodes, b \in Nodes: ctr[a] = ctr[b]
    /\ \A a \in Nodes, b \in Nodes: hmap[a] = hmap[b]
    /\ \A a \in Nodes, b \in Nodes, e \in Elements:
        Visible(adds[a], rems[a], e) = Visible(adds[b], rems[b], e)

=============================================================================
