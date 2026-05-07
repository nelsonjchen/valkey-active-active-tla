----------------------------- MODULE Persistence -----------------------------
EXTENDS Naturals

CONSTANTS Values

VARIABLES phase, val, clock, baseVal, baseClock, tailVal, tailPresent

vars == <<phase, val, clock, baseVal, baseClock, tailVal, tailPresent>>

Init ==
    /\ phase = "start"
    /\ val = "none"
    /\ clock = 0
    /\ baseVal = "none"
    /\ baseClock = 0
    /\ tailVal = "none"
    /\ tailPresent = FALSE

WriteBase ==
    /\ phase = "start"
    /\ val' = "baseFresh"
    /\ clock' = clock + 1
    /\ phase' = "baseWritten"
    /\ UNCHANGED <<baseVal, baseClock, tailVal, tailPresent>>

RewriteAofBase ==
    /\ phase = "baseWritten"
    /\ baseVal' = val
    /\ baseClock' = clock
    /\ phase' = "baseSaved"
    /\ UNCHANGED <<val, clock, tailVal, tailPresent>>

WriteTail ==
    /\ phase = "baseSaved"
    /\ val' = "tailFresh"
    /\ clock' = clock + 1
    /\ tailVal' = "tailFresh"
    /\ tailPresent' = TRUE
    /\ phase' = "tailWritten"
    /\ UNCHANGED <<baseVal, baseClock>>

RestartFromAof ==
    /\ phase = "tailWritten"
    /\ val' = IF tailPresent THEN tailVal ELSE baseVal
    \* The fixed implementation applies the base clock and stamps supported
    \* incremental AOF tail writes while loading.
    /\ clock' = IF tailPresent THEN baseClock + 1 ELSE baseClock
    /\ phase' = "restarted"
    /\ UNCHANGED <<baseVal, baseClock, tailVal, tailPresent>>

StaleRestore ==
    /\ phase = "restarted"
    /\ val' = IF 1 > clock THEN "stale" ELSE val
    /\ clock' = IF 1 > clock THEN 1 ELSE clock
    /\ phase' = "checked"
    /\ UNCHANGED <<baseVal, baseClock, tailVal, tailPresent>>

Next == WriteBase \/ RewriteAofBase \/ WriteTail \/ RestartFromAof \/ StaleRestore

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ phase \in {"start", "baseWritten", "baseSaved", "tailWritten", "restarted", "checked"}
    /\ val \in Values
    /\ baseVal \in Values
    /\ tailVal \in Values
    /\ clock \in Nat
    /\ baseClock \in Nat
    /\ tailPresent \in BOOLEAN

NoStaleAfterRestart ==
    phase = "checked" => val = "tailFresh"

=============================================================================
