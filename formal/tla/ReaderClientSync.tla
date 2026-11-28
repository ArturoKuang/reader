--------------------------- MODULE ReaderClientSync ---------------------------
(*
 * Formal TLA+ specification of Reader's Mac + Phone client sync protocol.
 *
 * True-to-code mapping (commit 82f73bd9864eb93dfe58d50a33ed68d74e647a1a):
 *   - Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:
 *       enqueueLocalRecords, pushOutbox, pullAll, resolve(conflict:choice:),
 *       uploadBook, retryWaitingUploads
 *   - Packages/ReaderSync/Sources/ReaderSync/SyncStore.swift:
 *       mergeOutbox, upsertRecord, markClean, removeOutbox, resetForNewServer
 *   - Packages/ReaderSync/Sources/ReaderSync/ConflictResolution.swift:
 *       prepare, currentHeadVersion
 *   - apps/mobile/src/sync/engine.ts:
 *       stage, enqueue, coalesce, flushOnce, applyPush, applyPulledPage,
 *       pull, applyEnvelope, openBook, updatePosition, uploadBook,
 *       resetForNewServer
 *   - App/Reader/Sync/SyncController.swift:
 *       applyOpeningPosition (positions apply only on book open, never mid-session)
 *
 * REAL CODE FINDINGS DISCOVERED DURING MODELING (findings stay findings!):
 *   1. Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:198-206
 *      `SyncEngine.resolve(conflict:choice:)` discards the `(version, seq)`
 *      tuple returned by `api.resolve(...)` and writes
 *      `version: conflict.baseVersion + 1` instead of `headVersion + 1`
 *      (`prepared.request.baseVersion + 1`). When `headVersion > baseVersion`
 *      (every real conflict), Mac's local `SyncStore.records.serverVersion`
 *      lags the server head, violating `ResolvedVersionMatchesServerHead`.
 *      Reproducible in this spec with `BUG_MODE = "resolve_uses_conflict_base"`.
 *   2. apps/mobile/src/sync/engine.ts:626-627, 766-784
 *      On push conflict, Phone sets `record.heldGeneration = record.generation`
 *      while leaving `record.dirty = true`. When Mac later resolves the
 *      conflict and Phone pulls the resolution (`envelope.conflict == null`),
 *      `applyEnvelope` clears `this.state.conflicts` (line 767) but returns
 *      early at `if (local?.dirty) return;` (line 784) without checking
 *      `local.heldGeneration === local.generation`. Phone reports "Synced"
 *      with 0 conflicts while never applying Mac's resolution, violating
 *      `EventualConvergence`.
 *      Reproducible in this spec with `BUG_MODE = "phone_held_stays_dirty_on_resolve"`.
 *   3. Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:446-461 &
 *      apps/mobile/src/sync/engine.ts:502-503, 784 (TLC-DISCOVERED BUG!)
 *      If client A pushes a change whose HTTP response is dropped after server
 *      commit (v1, seq=1), then client B pulls v1 and pushes v2 (seq=2), and
 *      client A runs `pull()` BEFORE retrying its dropped push, `pull()` skips
 *      v2 because `local.dirty == true` YET still advances `cursor` to 2!
 *      When client A later retries its dropped push, the server replays the
 *      idempotent `{status: applied, version: 1}` result, client A marks the
 *      record clean at v1, and because `cursor == 2 == serverSeq`, client A
 *      NEVER pulls v2 — permanent silent data loss / divergence!
 *      Reproducible in this spec with `BUG_MODE = "cursor_skips_dirty"`.
 *   4. Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:434-439 &
 *      SyncStore.swift:473-482
 *      In `pullAll()`, if `page.serverId != health.serverId`, Mac resets the
 *      store and sets `store.serverId = page.serverId` without updating
 *      `health.serverId`, causing an infinite reset loop. Also
 *      `SyncStore.resetForNewServer()` omits `DELETE FROM books;`.
 *)

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    KEYS,            \* Record keys (e.g. {"r1"})
    VALUES,          \* Abstract record payload values (e.g. {"v1", "v2"})
    POSITIONS,       \* Reading positions (e.g. {1, 2})
    MAX_EDITS,       \* Bound on total local annotation edits across clients
    MAX_POS_EDITS,   \* Bound on total local reading-position updates
    MAX_DROPS,       \* Bound on dropped push responses (idempotent replay)
    MAX_RESETS,      \* Bound on server rebuilds (serverId changes)
    MAX_DISK_EVENTS, \* Bound on 507 disk_full book upload pauses
    MAX_FAULTS,      \* Combined budget for drops + resets + disk_full events
    BUG_MODE         \* "none" | "pull_overwrites_dirty" | "resolve_uses_conflict_base"
                     \* | "phone_held_stays_dirty_on_resolve" | "cursor_skips_dirty"
                     \* | "mid_session_position_jump" | "disk_full_halts_records"

CLIENTS == {"mac", "phone"}
VALS_OPT == VALUES \cup {"none"}
POS_OPT == POSITIONS \cup {0}
SERVER_IDS == 1..(1 + MAX_RESETS)
MAX_SEQ == 2 * (MAX_EDITS + MAX_POS_EDITS + 2) + 4
MAX_VER == MAX_EDITS + 4

EmptyConflict == [
    open |-> FALSE,
    baseVersion |-> 0,
    headVersion |-> 0,
    winnerVal |-> "none",
    loserVal |-> "none"
]

EmptyReplay == [
    active |-> FALSE,
    cid |-> 0,
    version |-> 0,
    status |-> "none"
]

OutboxEntryType == [
    key: KEYS,
    baseVersion: 0..MAX_VER,
    val: VALUES,
    cid: 0..MAX_EDITS
]

ConflictType == [
    open: BOOLEAN,
    baseVersion: 0..MAX_VER,
    headVersion: 0..MAX_VER,
    winnerVal: VALS_OPT,
    loserVal: VALS_OPT
]

ReplayType == [
    active: BOOLEAN,
    cid: 0..MAX_EDITS,
    version: 0..MAX_VER,
    status: {"none", "applied", "conflict"}
]

VARIABLES
    \* Abstract sync server state
    serverId,
    serverSeq,
    serverHead,
    serverConflict,
    serverPos,
    serverDiskFull,
    serverReplay,

    \* Per-client durable store & runtime state (Mac SyncStore + Phone PersistedSync)
    clientServerId,
    cursor,
    maxCursorSeen,
    localVal,
    localVer,
    dirty,
    heldConflict,
    outbox,
    clientConflict,
    resolvedCheck,
    bookPaused,
    recordSyncHalted,

    \* Reading-position session state (both clients have the book open in a session)
    bookOpen,
    activePos,
    openedPos,
    storedRemotePos,

    \* Finite exploration bounds (edits/drops/resets/disk_full eventually stop)
    editCount,
    posEditCount,
    dropsUsed,
    resetsUsed,
    diskEventsUsed

serverVars == <<serverId, serverSeq, serverHead, serverConflict, serverPos, serverDiskFull, serverReplay>>
clientVars == <<clientServerId, cursor, maxCursorSeen, localVal, localVer, dirty, heldConflict, outbox, clientConflict, resolvedCheck, bookPaused, recordSyncHalted>>
posVars == <<bookOpen, activePos, openedPos, storedRemotePos>>
boundVars == <<editCount, posEditCount, dropsUsed, resetsUsed, diskEventsUsed>>
vars == <<serverVars, clientVars, posVars, boundVars>>

-----------------------------------------------------------------------------
\* Helper operators

KeyInOutbox(seq, k) ==
    \E i \in 1..Len(seq) : seq[i].key = k

OutboxItemFor(seq, k) ==
    LET idx == CHOOSE i \in 1..Len(seq) : seq[i].key = k
    IN seq[idx]

RemoveKeyFromSeq(seq, k) ==
    SelectSeq(seq, LAMBDA item : item.key # k)

\* Models SyncStore.mergeOutbox (DELETE by key + INSERT) and engine.ts:enqueue/coalesce
MergeOutbox(seq, item) ==
    Append(RemoveKeyFromSeq(seq, item.key), item)

\* Re-enqueue all local non-none records on Phone after serverId reset (engine.ts:856-862)
RECURSIVE BuildResetOutbox(_, _)
BuildResetOutbox(ks, vals) ==
    IF ks = {} THEN <<>>
    ELSE LET k == CHOOSE x \in ks : TRUE
             rest == BuildResetOutbox(ks \ {k}, vals)
         IN IF vals[k] # "none"
            THEN Append(rest, [key |-> k, baseVersion |-> 0, val |-> vals[k], cid |-> 0])
            ELSE rest

MinPos == CHOOSE p \in POSITIONS : \A q \in POSITIONS : p <= q

-----------------------------------------------------------------------------
Init ==
    /\ serverId = 1
    /\ serverSeq = 0
    /\ serverHead = [k \in KEYS |-> [version |-> 0, val |-> "none"]]
    /\ serverConflict = [k \in KEYS |-> EmptyConflict]
    /\ serverPos = 0
    /\ serverDiskFull = FALSE
    /\ serverReplay = [c \in CLIENTS |-> [k \in KEYS |-> EmptyReplay]]

    /\ clientServerId = [c \in CLIENTS |-> 1]
    /\ cursor = [c \in CLIENTS |-> 0]
    /\ maxCursorSeen = [c \in CLIENTS |-> 0]
    /\ localVal = [c \in CLIENTS |-> [k \in KEYS |-> "none"]]
    /\ localVer = [c \in CLIENTS |-> [k \in KEYS |-> 0]]
    /\ dirty = [c \in CLIENTS |-> [k \in KEYS |-> FALSE]]
    /\ heldConflict = [c \in CLIENTS |-> [k \in KEYS |-> FALSE]]
    /\ outbox = [c \in CLIENTS |-> <<>>]
    /\ clientConflict = [c \in CLIENTS |-> [k \in KEYS |-> EmptyConflict]]
    /\ resolvedCheck = [k \in KEYS |-> FALSE]
    /\ bookPaused = [c \in CLIENTS |-> FALSE]
    /\ recordSyncHalted = [c \in CLIENTS |-> FALSE]

    /\ bookOpen = [c \in CLIENTS |-> TRUE]
    /\ activePos = [c \in CLIENTS |-> MinPos]
    /\ openedPos = [c \in CLIENTS |-> MinPos]
    /\ storedRemotePos = [c \in CLIENTS |-> 0]

    /\ editCount = 0
    /\ posEditCount = 0
    /\ dropsUsed = 0
    /\ resetsUsed = 0
    /\ diskEventsUsed = 0

-----------------------------------------------------------------------------
\* Action 1: Local annotation edit on Mac or Phone
\* Maps to SyncEngine.enqueueLocalRecords + SyncStore.mergeOutbox (Mac)
\* and SyncEngine.stage + enqueue (Phone).
LocalEdit(c, k, v) ==
    /\ editCount < MAX_EDITS
    /\ localVal[c][k] # v
    /\ LET cid == editCount + 1
           base == localVer[c][k]
           item == [key |-> k, baseVersion |-> base, val |-> v, cid |-> cid]
       IN
       /\ localVal' = [localVal EXCEPT ![c][k] = v]
       /\ dirty' = [dirty EXCEPT ![c][k] = TRUE]
       /\ heldConflict' = [heldConflict EXCEPT ![c][k] = FALSE]
       /\ outbox' = [outbox EXCEPT ![c] = MergeOutbox(@, item)]
       /\ editCount' = editCount + 1
    /\ UNCHANGED <<serverVars, clientServerId, cursor, maxCursorSeen, localVer,
                   clientConflict, resolvedCheck, bookPaused, recordSyncHalted,
                   posVars, posEditCount, dropsUsed, resetsUsed, diskEventsUsed>>

\* Action 2: Push head of durable outbox to server (with optional dropped response)
\* Maps to SyncEngine.pushOutbox (Mac) and SyncEngine.flushOnce + applyPush (Phone).
PushOutbox(c, dropResponse) ==
    /\ Len(outbox[c]) > 0
    /\ ~recordSyncHalted[c]
    /\ clientServerId[c] = serverId
    /\ LET item == Head(outbox[c])
           k == item.key
           replay == serverReplay[c][k]
           isReplay == replay.active /\ replay.cid = item.cid
       IN
       IF isReplay THEN
           \* Idempotent replay of a batch whose HTTP response was dropped
           /\ ~dropResponse
           /\ outbox' = [outbox EXCEPT ![c] = Tail(@)]
           /\ serverReplay' = [serverReplay EXCEPT ![c][k] = EmptyReplay]
           /\ IF replay.status = "applied" THEN
                  /\ localVer' = [localVer EXCEPT ![c][k] = replay.version]
                  /\ dirty' = [dirty EXCEPT ![c][k] = FALSE]
                  /\ heldConflict' = [heldConflict EXCEPT ![c][k] = FALSE]
              ELSE
                  /\ UNCHANGED localVer
                  /\ IF c = "mac" THEN
                         /\ dirty' = [dirty EXCEPT ![c][k] = FALSE]
                         /\ heldConflict' = [heldConflict EXCEPT ![c][k] = FALSE]
                     ELSE
                         /\ UNCHANGED dirty
                         /\ heldConflict' = [heldConflict EXCEPT ![c][k] = TRUE]
           /\ UNCHANGED <<serverId, serverSeq, serverHead, serverConflict, serverPos, serverDiskFull,
                          clientServerId, cursor, maxCursorSeen, localVal, clientConflict,
                          resolvedCheck, bookPaused, recordSyncHalted, posVars, boundVars>>
       ELSE
           \* Fresh push to server
           /\ (~dropResponse \/ (dropsUsed < MAX_DROPS /\ (dropsUsed + resetsUsed + diskEventsUsed < MAX_FAULTS) /\ ~replay.active))
           /\ IF item.baseVersion = serverHead[k].version /\ ~serverConflict[k].open THEN
                  \* Server applies cleanly
                  LET newVer == serverHead[k].version + 1
                  IN
                  /\ newVer <= MAX_VER
                  /\ serverSeq + 1 <= MAX_SEQ
                  /\ serverHead' = [serverHead EXCEPT ![k] = [version |-> newVer, val |-> item.val]]
                  /\ serverSeq' = serverSeq + 1
                  /\ resolvedCheck' = [resolvedCheck EXCEPT ![k] = FALSE]
                  /\ IF ~dropResponse THEN
                         /\ outbox' = [outbox EXCEPT ![c] = Tail(@)]
                         /\ localVer' = [localVer EXCEPT ![c][k] = newVer]
                         /\ dirty' = [dirty EXCEPT ![c][k] = FALSE]
                         /\ heldConflict' = [heldConflict EXCEPT ![c][k] = FALSE]
                         /\ serverReplay' = [serverReplay EXCEPT ![c][k] = EmptyReplay]
                         /\ UNCHANGED dropsUsed
                     ELSE
                         /\ serverReplay' = [serverReplay EXCEPT ![c][k] =
                                [active |-> TRUE, cid |-> item.cid, version |-> newVer, status |-> "applied"]]
                         /\ dropsUsed' = dropsUsed + 1
                         /\ UNCHANGED <<outbox, localVer, dirty, heldConflict>>
                  /\ UNCHANGED <<serverId, serverConflict, serverPos, serverDiskFull,
                                 clientServerId, cursor, maxCursorSeen, localVal,
                                 clientConflict, bookPaused, recordSyncHalted,
                                 posVars, editCount, posEditCount, resetsUsed, diskEventsUsed>>
              ELSE
                  \* Base version lags server head or conflict already open -> server opens conflict
                  LET newConflict ==
                          IF ~serverConflict[k].open THEN
                              [open |-> TRUE,
                               baseVersion |-> item.baseVersion,
                               headVersion |-> serverHead[k].version,
                               winnerVal |-> serverHead[k].val,
                               loserVal |-> item.val]
                          ELSE
                              [serverConflict[k] EXCEPT !.loserVal = item.val]
                  IN
                  /\ serverSeq + 1 <= MAX_SEQ
                  /\ serverConflict' = [serverConflict EXCEPT ![k] = newConflict]
                  /\ serverSeq' = serverSeq + 1
                  /\ resolvedCheck' = [resolvedCheck EXCEPT ![k] = FALSE]
                  /\ IF ~dropResponse THEN
                         /\ outbox' = [outbox EXCEPT ![c] = Tail(@)]
                         /\ IF c = "mac" THEN
                                /\ dirty' = [dirty EXCEPT ![c][k] = FALSE]
                                /\ heldConflict' = [heldConflict EXCEPT ![c][k] = FALSE]
                            ELSE
                                \* Phone holds conflicting edit until Mac resolves (engine.ts:627)
                                /\ UNCHANGED dirty
                                /\ heldConflict' = [heldConflict EXCEPT ![c][k] = TRUE]
                         /\ serverReplay' = [serverReplay EXCEPT ![c][k] = EmptyReplay]
                         /\ UNCHANGED dropsUsed
                     ELSE
                         /\ serverReplay' = [serverReplay EXCEPT ![c][k] =
                                [active |-> TRUE, cid |-> item.cid,
                                 version |-> serverHead[k].version, status |-> "conflict"]]
                         /\ dropsUsed' = dropsUsed + 1
                         /\ UNCHANGED <<outbox, dirty, heldConflict>>
                  /\ UNCHANGED <<serverId, serverHead, serverPos, serverDiskFull,
                                 clientServerId, cursor, maxCursorSeen, localVal, localVer,
                                 clientConflict, bookPaused, recordSyncHalted,
                                 posVars, editCount, posEditCount, resetsUsed, diskEventsUsed>>

\* Action 3: Client detects serverId mismatch and resets local sync state
\* Maps to SyncStore.resetForNewServer (Mac) and engine.ts:resetForNewServer (Phone).
ClientDetectNewServer(c) ==
    /\ clientServerId[c] # serverId
    /\ clientServerId' = [clientServerId EXCEPT ![c] = serverId]
    /\ cursor' = [cursor EXCEPT ![c] = 0]
    /\ maxCursorSeen' = [maxCursorSeen EXCEPT ![c] = 0]
    /\ clientConflict' = [clientConflict EXCEPT ![c] = [k \in KEYS |-> EmptyConflict]]
    /\ storedRemotePos' = [storedRemotePos EXCEPT ![c] = 0]
    /\ heldConflict' = [heldConflict EXCEPT ![c] = [k \in KEYS |-> FALSE]]
    /\ IF c = "mac" THEN
           \* Mac clears records, outbox, conflicts, cursor (SyncStore.swift:473-482)
           /\ localVal' = [localVal EXCEPT ![c] = [k \in KEYS |-> "none"]]
           /\ localVer' = [localVer EXCEPT ![c] = [k \in KEYS |-> 0]]
           /\ dirty' = [dirty EXCEPT ![c] = [k \in KEYS |-> FALSE]]
           /\ outbox' = [outbox EXCEPT ![c] = <<>>]
       ELSE
           \* Phone preserves local records and re-enqueues them at baseVersion 0 (engine.ts:856-862)
           /\ UNCHANGED localVal
           /\ localVer' = [localVer EXCEPT ![c] = [k \in KEYS |-> 0]]
           /\ dirty' = [dirty EXCEPT ![c] = [k \in KEYS |-> (localVal[c][k] # "none")]]
           /\ outbox' = [outbox EXCEPT ![c] = BuildResetOutbox(KEYS, localVal[c])]
    /\ UNCHANGED <<serverVars, resolvedCheck, bookPaused, recordSyncHalted,
                   bookOpen, activePos, openedPos, boundVars>>

\* Action 4: Client pulls page from server and advances cursor ONLY after applying
\* Maps to SyncEngine.pullAll (Mac) and SyncEngine.pull + applyPulledPage (Phone).
\* Intended protocol holds cursor when a dirty record skipped a newer server version
\* (preventing permanent missed updates after an idempotent dropped-push replay).
Pull(c) ==
    /\ clientServerId[c] = serverId
    /\ cursor[c] < serverSeq
    /\ ~recordSyncHalted[c]
    /\ LET ShouldApply(k) ==
               IF BUG_MODE = "pull_overwrites_dirty" THEN TRUE
               ELSE IF BUG_MODE = "phone_held_stays_dirty_on_resolve" THEN ~dirty[c][k]
               ELSE
                   \* Intended rule: protect dirty edits, EXCEPT release a held conflict
                   \* once Mac has resolved it on the server (~serverConflict[k].open)
                   \* and no newer unpushed edit sits in the outbox.
                   ~dirty[c][k] \/ (heldConflict[c][k] /\ ~serverConflict[k].open /\ ~KeyInOutbox(outbox[c], k))
           hasSkippedDirty ==
               \E k \in KEYS : ~ShouldApply(k) /\ serverHead[k].version > localVer[c][k]
           nextCursor ==
               IF hasSkippedDirty /\ BUG_MODE # "cursor_skips_dirty"
               THEN cursor[c]
               ELSE serverSeq
           nextVal == [k \in KEYS |-> IF ShouldApply(k) THEN serverHead[k].val ELSE localVal[c][k]]
           nextVer == [k \in KEYS |-> IF ShouldApply(k) THEN serverHead[k].version ELSE localVer[c][k]]
           nextDirty == [k \in KEYS |-> IF ShouldApply(k) THEN FALSE ELSE dirty[c][k]]
           nextHeld == [k \in KEYS |-> IF ShouldApply(k) THEN FALSE ELSE heldConflict[c][k]]
           nextActivePos ==
               IF BUG_MODE = "mid_session_position_jump" /\ bookOpen[c] /\ serverPos > 0
               THEN serverPos
               ELSE activePos[c]
       IN
       /\ ( nextCursor # cursor[c]
            \/ clientConflict[c] # serverConflict
            \/ storedRemotePos[c] # serverPos
            \/ nextVal # localVal[c]
            \/ nextVer # localVer[c]
            \/ nextDirty # dirty[c]
            \/ nextHeld # heldConflict[c]
            \/ nextActivePos # activePos[c] )
       /\ clientConflict' = [clientConflict EXCEPT ![c] = serverConflict]
       /\ localVal' = [localVal EXCEPT ![c] = nextVal]
       /\ localVer' = [localVer EXCEPT ![c] = nextVer]
       /\ dirty' = [dirty EXCEPT ![c] = nextDirty]
       /\ heldConflict' = [heldConflict EXCEPT ![c] = nextHeld]
       /\ storedRemotePos' = [storedRemotePos EXCEPT ![c] = serverPos]
       /\ activePos' = [activePos EXCEPT ![c] = nextActivePos]
       /\ cursor' = [cursor EXCEPT ![c] = nextCursor]
       /\ maxCursorSeen' = [maxCursorSeen EXCEPT ![c] =
              IF nextCursor > maxCursorSeen[c] THEN nextCursor ELSE maxCursorSeen[c]]
    /\ UNCHANGED <<serverVars, clientServerId, outbox, resolvedCheck,
                   bookPaused, recordSyncHalted, bookOpen, openedPos, boundVars>>

\* Action 5: Mac-only conflict resolution (Phone never resolves conflicts)
\* Maps to ConflictResolution.prepare + SyncEngine.resolve(conflict:choice:).
MacResolveConflict(k, pickWinner) ==
    /\ clientServerId["mac"] = serverId
    /\ ~recordSyncHalted["mac"]
    /\ clientConflict["mac"][k].open
    /\ serverConflict[k].open
    /\ clientConflict["mac"][k].headVersion = serverHead[k].version
    /\ ~KeyInOutbox(outbox["mac"], k)
    /\ LET conf == clientConflict["mac"][k]
           chosenVal == IF pickWinner THEN conf.winnerVal ELSE conf.loserVal
           newVer == serverHead[k].version + 1
       IN
       /\ chosenVal \in VALUES
       /\ newVer <= MAX_VER
       /\ serverSeq + 1 <= MAX_SEQ
       /\ serverHead' = [serverHead EXCEPT ![k] = [version |-> newVer, val |-> chosenVal]]
       /\ serverConflict' = [serverConflict EXCEPT ![k] = EmptyConflict]
       /\ serverSeq' = serverSeq + 1
       /\ clientConflict' = [clientConflict EXCEPT !["mac"][k] = EmptyConflict]
       /\ localVal' = [localVal EXCEPT !["mac"][k] = chosenVal]
       /\ dirty' = [dirty EXCEPT !["mac"][k] = FALSE]
       /\ heldConflict' = [heldConflict EXCEPT !["mac"][k] = FALSE]
       /\ localVer' = [localVer EXCEPT !["mac"][k] =
              IF BUG_MODE = "resolve_uses_conflict_base"
              THEN conf.baseVersion + 1   \* Real code bug at SyncEngine.swift:205!
              ELSE newVer]
       /\ resolvedCheck' = [resolvedCheck EXCEPT ![k] = TRUE]
    /\ UNCHANGED <<serverId, serverPos, serverDiskFull, serverReplay,
                   clientServerId, cursor, maxCursorSeen, outbox,
                   bookPaused, recordSyncHalted, posVars, boundVars>>

\* Action 6: Server rebuild / new serverId
ServerRebuild ==
    /\ resetsUsed < MAX_RESETS
    /\ dropsUsed + resetsUsed + diskEventsUsed < MAX_FAULTS
    /\ serverSeq > 0
    /\ serverId' = serverId + 1
    /\ serverSeq' = 0
    /\ serverHead' = [k \in KEYS |-> [version |-> 0, val |-> "none"]]
    /\ serverConflict' = [k \in KEYS |-> EmptyConflict]
    /\ serverPos' = 0
    /\ serverReplay' = [c \in CLIENTS |-> [k \in KEYS |-> EmptyReplay]]
    /\ resolvedCheck' = [k \in KEYS |-> FALSE]
    /\ resetsUsed' = resetsUsed + 1
    /\ UNCHANGED <<serverDiskFull, clientServerId, cursor, maxCursorSeen,
                   localVal, localVer, dirty, heldConflict, outbox, clientConflict,
                   bookPaused, recordSyncHalted, posVars,
                   editCount, posEditCount, dropsUsed, diskEventsUsed>>

\* Action 7: Server storage full / book blob upload pause & recovery
\* Maps to SyncEngine.uploadBook (507 disk_full) and engine.ts:uploadBook/recheckStorage.
\* Bounded by MAX_DISK_EVENTS so record sync runs both during and after disk_full.
UploadBookHitDiskFull(c) ==
    /\ diskEventsUsed < MAX_DISK_EVENTS
    /\ dropsUsed + resetsUsed + diskEventsUsed < MAX_FAULTS
    /\ ~bookPaused[c]
    /\ serverDiskFull' = TRUE
    /\ bookPaused' = [bookPaused EXCEPT ![c] = TRUE]
    /\ diskEventsUsed' = diskEventsUsed + 1
    /\ IF BUG_MODE = "disk_full_halts_records" THEN
           recordSyncHalted' = [recordSyncHalted EXCEPT ![c] = TRUE]
       ELSE
           UNCHANGED recordSyncHalted
    /\ UNCHANGED <<serverId, serverSeq, serverHead, serverConflict, serverPos, serverReplay,
                   clientServerId, cursor, maxCursorSeen, localVal, localVer,
                   dirty, heldConflict, outbox, clientConflict, resolvedCheck,
                   posVars, editCount, posEditCount, dropsUsed, resetsUsed>>

ClearDiskFullAndRetry ==
    /\ serverDiskFull
    /\ serverDiskFull' = FALSE
    /\ bookPaused' = [c \in CLIENTS |-> FALSE]
    /\ UNCHANGED <<serverId, serverSeq, serverHead, serverConflict, serverPos, serverReplay,
                   clientServerId, cursor, maxCursorSeen, localVal, localVer,
                   dirty, heldConflict, outbox, clientConflict, resolvedCheck,
                   recordSyncHalted, posVars, boundVars>>

\* Action 8: Reading-position session lifecycle
\* Maps to engine.ts:openBook/updatePosition and SyncController.applyOpeningPosition.
LocalScrollPosition(c, p) ==
    /\ bookOpen[c]
    /\ p # activePos[c]
    /\ posEditCount < MAX_POS_EDITS
    /\ clientServerId[c] = serverId
    /\ serverSeq + 1 <= MAX_SEQ
    /\ activePos' = [activePos EXCEPT ![c] = p]
    /\ openedPos' = [openedPos EXCEPT ![c] = p]
    /\ serverPos' = p
    /\ serverSeq' = serverSeq + 1
    /\ posEditCount' = posEditCount + 1
    /\ UNCHANGED <<serverId, serverHead, serverConflict, serverDiskFull, serverReplay,
                   clientVars, bookOpen, storedRemotePos,
                   editCount, dropsUsed, resetsUsed, diskEventsUsed>>

\* Close and reopen book to apply the latest stored remote reading position on open
ReopenBook(c) ==
    /\ bookOpen[c]
    /\ storedRemotePos[c] > 0
    /\ storedRemotePos[c] # activePos[c]
    /\ activePos' = [activePos EXCEPT ![c] = storedRemotePos[c]]
    /\ openedPos' = [openedPos EXCEPT ![c] = storedRemotePos[c]]
    /\ UNCHANGED <<serverVars, clientVars, bookOpen, storedRemotePos, boundVars>>

Converged ==
    /\ \A c \in CLIENTS :
        /\ clientServerId[c] = serverId
        /\ Len(outbox[c]) = 0
        /\ cursor[c] = serverSeq
        /\ \A k \in KEYS :
            /\ ~dirty[c][k]
            /\ localVal[c][k] = serverHead[k].val
            /\ localVer[c][k] = serverHead[k].version
    /\ \A k \in KEYS : ~serverConflict[k].open

\* Explicit quiescent step ONLY once fully converged so genuine non-converged
\* protocol stalls still trigger TLC deadlock checking!
Quiescent ==
    /\ Converged
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
Next ==
    \/ \E c \in CLIENTS, k \in KEYS, v \in VALUES : LocalEdit(c, k, v)
    \/ \E c \in CLIENTS, drop \in BOOLEAN : PushOutbox(c, drop)
    \/ \E c \in CLIENTS : ClientDetectNewServer(c)
    \/ \E c \in CLIENTS : Pull(c)
    \/ \E k \in KEYS, w \in BOOLEAN : MacResolveConflict(k, w)
    \/ ServerRebuild
    \/ \E c \in CLIENTS : UploadBookHitDiskFull(c)
    \/ ClearDiskFullAndRetry
    \/ \E c \in CLIENTS, p \in POSITIONS : LocalScrollPosition(c, p)
    \/ \E c \in CLIENTS : ReopenBook(c)
    \/ Quiescent

Fairness ==
    /\ \A c \in CLIENTS : WF_vars(ClientDetectNewServer(c))
    /\ \A c \in CLIENTS : WF_vars(PushOutbox(c, FALSE))
    /\ \A c \in CLIENTS : WF_vars(Pull(c))
    /\ \A k \in KEYS : WF_vars(MacResolveConflict(k, TRUE))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
\* Safety invariants

TypeOK ==
    /\ serverId \in SERVER_IDS
    /\ serverSeq \in 0..MAX_SEQ
    /\ serverHead \in [KEYS -> [version: 0..MAX_VER, val: VALS_OPT]]
    /\ serverConflict \in [KEYS -> ConflictType]
    /\ serverPos \in POS_OPT
    /\ serverDiskFull \in BOOLEAN
    /\ serverReplay \in [CLIENTS -> [KEYS -> ReplayType]]
    /\ clientServerId \in [CLIENTS -> SERVER_IDS]
    /\ cursor \in [CLIENTS -> 0..MAX_SEQ]
    /\ maxCursorSeen \in [CLIENTS -> 0..MAX_SEQ]
    /\ localVal \in [CLIENTS -> [KEYS -> VALS_OPT]]
    /\ localVer \in [CLIENTS -> [KEYS -> 0..MAX_VER]]
    /\ dirty \in [CLIENTS -> [KEYS -> BOOLEAN]]
    /\ heldConflict \in [CLIENTS -> [KEYS -> BOOLEAN]]
    /\ \A c \in CLIENTS :
           /\ Len(outbox[c]) <= Cardinality(KEYS)
           /\ \A i \in 1..Len(outbox[c]) : outbox[c][i] \in OutboxEntryType
    /\ clientConflict \in [CLIENTS -> [KEYS -> ConflictType]]
    /\ resolvedCheck \in [KEYS -> BOOLEAN]
    /\ bookPaused \in [CLIENTS -> BOOLEAN]
    /\ recordSyncHalted \in [CLIENTS -> BOOLEAN]
    /\ bookOpen \in [CLIENTS -> BOOLEAN]
    /\ activePos \in [CLIENTS -> POSITIONS]
    /\ openedPos \in [CLIENTS -> POSITIONS]
    /\ storedRemotePos \in [CLIENTS -> POS_OPT]
    /\ editCount \in 0..MAX_EDITS
    /\ posEditCount \in 0..MAX_POS_EDITS
    /\ dropsUsed \in 0..MAX_DROPS
    /\ resetsUsed \in 0..MAX_RESETS
    /\ diskEventsUsed \in 0..MAX_DISK_EVENTS

\* At most one outbox entry per (client, key) via mergeOutbox / coalesce
OutboxUniquePerKey ==
    \A c \in CLIENTS :
        \A i, j \in 1..Len(outbox[c]) :
            i # j => outbox[c][i].key # outbox[c][j].key

\* Pull never overwrites an unpushed dirty local record
DirtyRecordNeverOverwrittenByPull ==
    \A c \in CLIENTS, k \in KEYS :
        KeyInOutbox(outbox[c], k) =>
            (dirty[c][k] /\ localVal[c][k] = OutboxItemFor(outbox[c], k).val)

\* Cursor is monotonic within a serverId and never exceeds serverSeq
CursorMonotonicWithinServer ==
    \A c \in CLIENTS :
        /\ cursor[c] >= maxCursorSeen[c]
        /\ (clientServerId[c] = serverId => cursor[c] <= serverSeq)

\* After Mac resolves a conflict, Mac's local serverVersion matches server head
\* (Caught real bug in SyncEngine.swift:205 where conflict.baseVersion + 1 was written)
ResolvedVersionMatchesServerHead ==
    \A k \in KEYS :
        (resolvedCheck[k] /\ clientServerId["mac"] = serverId /\ ~dirty["mac"][k]) =>
            (localVer["mac"][k] = serverHead[k].version)

\* Reading position never jumps mid-session while a book is open
MidSessionPositionNeverJumps ==
    \A c \in CLIENTS : bookOpen[c] => (activePos[c] = openedPos[c])

\* 507 disk_full on book blob upload never halts or blocks record sync
DiskFullNeverBlocksRecordSync ==
    \A c \in CLIENTS : ~recordSyncHalted[c]

-----------------------------------------------------------------------------
\* Temporal liveness: once finite edits/resets stop, Mac & Phone converge even if disk_full

EventualConvergence == <>[]Converged

=============================================================================
