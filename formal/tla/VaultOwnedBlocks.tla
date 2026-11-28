--------------------------- MODULE VaultOwnedBlocks ---------------------------
(*
 * Formal TLA+ specification of Reader's Obsidian vault Markdown owned-block
 * synchronization, 3-way external-edit merge, own-write echo suppression,
 * and Q-M1 missing-file delete guard.
 *
 * True-to-code mapping (commit 82f73bd9864eb93dfe58d50a33ed68d74e647a1a):
 *   - Packages/ReaderCore/Sources/ReaderCore/OwnedBlocks.swift:
 *       OwnedBlocks.parse, OwnedBlocks.render, OwnedBlocks.body,
 *       OwnedBlocks.upsert, OwnedBlocks.remove
 *   - Packages/ReaderCore/Sources/ReaderCore/VaultSync.swift:
 *       VaultSync.applyExternal, VaultSync.isOwnWrite
 *   - Packages/ReaderCore/Sources/ReaderCore/Annotations.swift:
 *       VaultAnnotationSync.render
 *   - App/Reader/VaultCoordinator.swift:
 *       VaultCoordinator.reload, VaultCoordinator.mergeExternal,
 *       VaultCoordinator.writeNotes, VaultCoordinator.writeIfChanged,
 *       VaultCoordinator.flush
 *   - Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:
 *       enqueueLocalRecords (Q-M1: missing chapter files never synthesize deletes)
 *
 * REAL CODE FINDINGS DISCOVERED DURING MODELING (findings stay findings!):
 *   1. App/Reader/VaultCoordinator.swift:255-282 (`VaultCoordinator.writeNotes`)
 *      `writeNotes` reads the current file from disk (`fs.readString(path)`) and
 *      unconditionally overwrites every annotation block via
 *      `VaultAnnotationSync.render` (`OwnedBlocks.upsert`) WITHOUT comparing
 *      against `lastWritten[path]` or invoking `VaultSync.applyExternal`. If
 *      Obsidian edits an owned block during the 0.25s `VaultFolderWatcher`
 *      debounce window before `reload(mergePending: true)` fires and Reader
 *      flushes first, `writeNotes` silently clobbers Obsidian's external edit.
 *      Reproducible in this spec with `BUG_MODE = "clobber_external_edit"`.
 *   2. App/Reader/VaultCoordinator.swift:309-316 (`writeIfChanged`)
 *      `writeIfChanged` unconditionally sets `applyingOwnWrite = false` at
 *      line 315, cancelling `holdOwnWrite()`'s 0.45s debounce guard immediately;
 *      echo suppression then relies solely on `VaultSync.isOwnWrite`.
 *   3. App/Reader/VaultCoordinator.swift:168-178 (`reload(mergePending: true)`)
 *      When a chapter `.md` file is deleted/renamed externally, `reload`
 *      preserves unlinked `session.notes`, but drops `session.highlights` from
 *      the missing file (though `SyncEngine.enqueueLocalRecords` still avoids
 *      pushing delete tombstones to the sync server).
 *)

EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    BLOCK_IDS,    \* Reader-owned block IDs in a chapter .md file (e.g. {"b1", "b2"})
    VALUES,       \* Abstract block body versions (e.g. {"v0", "v1", "v2"})
    USER_TEXTS,   \* Abstract user-authored Markdown slices (e.g. {"u0", "u1"})
    MAX_OPS,      \* Bound on total Reader/Obsidian user edit operations
    BUG_MODE      \* "none" | "clobber_external_edit" | "corrupt_user_text"
                  \* | "missing_file_pushes_delete" | "ignore_is_own_write"

SLOTS == {1, 2}
BODY_SETS == SUBSET VALUES
OPT_VAL == VALUES \cup {"none"}

InitVal == CHOOSE v \in VALUES : TRUE
InitUser == CHOOSE u \in USER_TEXTS : TRUE
FirstBlock == CHOOSE b \in BLOCK_IDS : TRUE

VARIABLES
    \* Disk state of the chapter Markdown file
    fileExists,
    diskUserSlices,
    expectedUserSlices,
    diskBlocks,

    \* Reader session & VaultCoordinator state
    sessionBlocks,
    writtenBlocks,
    lastWrittenUserSlices,
    hasLastWritten,
    loadedBlockIDs,
    readerDirty,
    watcherPending,

    \* Tracking external edits, conflict markers, delete provenance, echo guard
    extUnseenEdit,
    conflictBlocks,
    explicitDeletes,
    pushedDeletes,
    spuriousEchoMerge,

    \* Finite operation bound
    ops

diskVars == <<fileExists, diskUserSlices, expectedUserSlices, diskBlocks>>
readerVars == <<sessionBlocks, writtenBlocks, lastWrittenUserSlices, hasLastWritten, loadedBlockIDs, readerDirty, watcherPending>>
auditVars == <<extUnseenEdit, conflictBlocks, explicitDeletes, pushedDeletes, spuriousEchoMerge>>
vars == <<diskVars, readerVars, auditVars, ops>>

-----------------------------------------------------------------------------
\* Helper operators

IsOwnWrite ==
    /\ fileExists
    /\ hasLastWritten
    /\ diskUserSlices = lastWrittenUserSlices
    /\ diskBlocks = writtenBlocks

\* 3-way merge of one block per VaultSync.applyExternal (VaultSync.swift:22-34)
MergedBlock(b) ==
    LET pending == sessionBlocks[b]
        remote == diskBlocks[b]
        base == writtenBlocks[b]
        readerChanged == (pending # base)
        diskChanged == (remote # base)
    IN
    IF readerChanged /\ diskChanged /\ (remote # pending)
    THEN pending \cup remote   \* Conflict: keep both bodies (+ warning callout)
    ELSE IF readerChanged
         THEN pending
         ELSE remote

IsBlockConflict(b) ==
    LET pending == sessionBlocks[b]
        remote == diskBlocks[b]
        base == writtenBlocks[b]
    IN (pending # base) /\ (remote # base) /\ (remote # pending)

-----------------------------------------------------------------------------
Init ==
    /\ fileExists = TRUE
    /\ diskUserSlices = [s \in SLOTS |-> InitUser]
    /\ expectedUserSlices = [s \in SLOTS |-> InitUser]
    /\ diskBlocks = [b \in BLOCK_IDS |-> IF b = FirstBlock THEN {InitVal} ELSE {}]

    /\ sessionBlocks = [b \in BLOCK_IDS |-> IF b = FirstBlock THEN {InitVal} ELSE {}]
    /\ writtenBlocks = [b \in BLOCK_IDS |-> IF b = FirstBlock THEN {InitVal} ELSE {}]
    /\ lastWrittenUserSlices = [s \in SLOTS |-> InitUser]
    /\ hasLastWritten = TRUE
    /\ loadedBlockIDs = {FirstBlock}
    /\ readerDirty = FALSE
    /\ watcherPending = FALSE

    /\ extUnseenEdit = [b \in BLOCK_IDS |-> "none"]
    /\ conflictBlocks = {}
    /\ explicitDeletes = {}
    /\ pushedDeletes = {}
    /\ spuriousEchoMerge = FALSE

    /\ ops = 0

-----------------------------------------------------------------------------
\* Action 1: Reader local edit/upsert of an owned block in session memory
ReaderEditBlock(b, v) ==
    /\ ops < MAX_OPS
    /\ sessionBlocks[b] # {v}
    /\ sessionBlocks' = [sessionBlocks EXCEPT ![b] = {v}]
    /\ readerDirty' = TRUE
    /\ ops' = ops + 1
    /\ UNCHANGED <<diskVars, writtenBlocks, lastWrittenUserSlices, hasLastWritten,
                   loadedBlockIDs, watcherPending, extUnseenEdit, conflictBlocks,
                   explicitDeletes, pushedDeletes, spuriousEchoMerge>>

\* Action 2: Reader explicit delete of an annotation in session memory
ReaderRemoveBlock(b) ==
    /\ ops < MAX_OPS
    /\ sessionBlocks[b] # {}
    /\ sessionBlocks' = [sessionBlocks EXCEPT ![b] = {}]
    /\ readerDirty' = TRUE
    /\ explicitDeletes' = explicitDeletes \cup {b}
    /\ pushedDeletes' = pushedDeletes \cup {b}
    /\ ops' = ops + 1
    /\ UNCHANGED <<diskVars, writtenBlocks, lastWrittenUserSlices, hasLastWritten,
                   loadedBlockIDs, watcherPending, extUnseenEdit, conflictBlocks,
                   spuriousEchoMerge>>

\* Action 3: Reader flushes local edits to the vault Markdown file
\* Maps to VaultCoordinator.flush -> writeNotes -> VaultAnnotationSync.render -> writeIfChanged.
\* Safe mode reconciles external disk edits via VaultSync.applyExternal before writing.
\* Canary mode ("clobber_external_edit") reproduces the VaultCoordinator.writeNotes race.
ReaderFlush ==
    /\ fileExists
    /\ readerDirty
    /\ IF BUG_MODE = "clobber_external_edit" THEN
           \* Direct OwnedBlocks.upsert over current disk without checking lastWritten / applyExternal
           /\ diskBlocks' = [b \in BLOCK_IDS |->
                  IF sessionBlocks[b] # {} THEN sessionBlocks[b]
                  ELSE IF b \in loadedBlockIDs THEN {}
                  ELSE diskBlocks[b]]
           /\ writtenBlocks' = diskBlocks'
           /\ lastWrittenUserSlices' = diskUserSlices
           /\ hasLastWritten' = TRUE
           /\ loadedBlockIDs' = {b \in BLOCK_IDS : diskBlocks'[b] # {}}
           /\ readerDirty' = FALSE
           /\ watcherPending' = TRUE
           /\ UNCHANGED <<fileExists, diskUserSlices, expectedUserSlices, sessionBlocks,
                          extUnseenEdit, conflictBlocks, explicitDeletes, pushedDeletes,
                          spuriousEchoMerge, ops>>
       ELSE
           LET merged == [b \in BLOCK_IDS |-> MergedBlock(b)]
               newConflicts == {b \in BLOCK_IDS : IsBlockConflict(b)}
               nextUserSlices ==
                   IF BUG_MODE = "corrupt_user_text"
                   THEN [s \in SLOTS |-> CHOOSE u \in USER_TEXTS : u # diskUserSlices[s]]
                   ELSE diskUserSlices
           IN
           /\ diskUserSlices' = nextUserSlices
           /\ diskBlocks' = merged
           /\ sessionBlocks' = merged
           /\ writtenBlocks' = merged
           /\ lastWrittenUserSlices' = nextUserSlices
           /\ hasLastWritten' = TRUE
           /\ loadedBlockIDs' = {b \in BLOCK_IDS : merged[b] # {}}
           /\ readerDirty' = FALSE
           /\ watcherPending' = TRUE
           /\ extUnseenEdit' = [b \in BLOCK_IDS |-> "none"]
           /\ conflictBlocks' = conflictBlocks \cup newConflicts
           /\ UNCHANGED <<fileExists, expectedUserSlices, explicitDeletes, pushedDeletes,
                          spuriousEchoMerge, ops>>

\* Action 4: External Obsidian edit to user-authored Markdown outside Reader markers
ObsidianEditUserText(s, u) ==
    /\ ops < MAX_OPS
    /\ fileExists
    /\ diskUserSlices[s] # u
    /\ diskUserSlices' = [diskUserSlices EXCEPT ![s] = u]
    /\ expectedUserSlices' = [expectedUserSlices EXCEPT ![s] = u]
    /\ watcherPending' = TRUE
    /\ ops' = ops + 1
    /\ UNCHANGED <<fileExists, diskBlocks, sessionBlocks, writtenBlocks,
                   lastWrittenUserSlices, hasLastWritten, loadedBlockIDs, readerDirty,
                   auditVars>>

\* Action 5: External Obsidian edit inside a Reader-owned block on disk
ObsidianEditOwnedBlock(b, v) ==
    /\ ops < MAX_OPS
    /\ fileExists
    /\ diskBlocks[b] # {v}
    /\ diskBlocks' = [diskBlocks EXCEPT ![b] = {v}]
    /\ extUnseenEdit' = [extUnseenEdit EXCEPT ![b] = v]
    /\ watcherPending' = TRUE
    /\ ops' = ops + 1
    /\ UNCHANGED <<fileExists, diskUserSlices, expectedUserSlices,
                   sessionBlocks, writtenBlocks, lastWrittenUserSlices, hasLastWritten,
                   loadedBlockIDs, readerDirty, conflictBlocks, explicitDeletes,
                   pushedDeletes, spuriousEchoMerge>>

\* Action 6: External Obsidian delete or rename of the chapter .md file (Q-M1)
ObsidianDeleteOrRenameFile ==
    /\ ops < MAX_OPS
    /\ fileExists
    /\ fileExists' = FALSE
    /\ watcherPending' = TRUE
    /\ extUnseenEdit' = [b \in BLOCK_IDS |-> "none"]
    /\ ops' = ops + 1
    /\ UNCHANGED <<diskUserSlices, expectedUserSlices, diskBlocks,
                   sessionBlocks, writtenBlocks, lastWrittenUserSlices, hasLastWritten,
                   loadedBlockIDs, readerDirty, conflictBlocks, explicitDeletes,
                   pushedDeletes, spuriousEchoMerge>>

\* Action 7: File reappears (e.g. Obsidian rename-back or restore from Trash)
ObsidianRestoreFile ==
    /\ ops < MAX_OPS
    /\ ~fileExists
    /\ fileExists' = TRUE
    /\ diskUserSlices' = expectedUserSlices
    /\ watcherPending' = TRUE
    /\ ops' = ops + 1
    /\ UNCHANGED <<expectedUserSlices, diskBlocks,
                   sessionBlocks, writtenBlocks, lastWrittenUserSlices, hasLastWritten,
                   loadedBlockIDs, readerDirty, auditVars>>

\* Action 8: VaultFolderWatcher fires reload(mergePending: true)
\* Maps to VaultCoordinator.reload + VaultSync.isOwnWrite + VaultSync.applyExternal.
WatcherFire ==
    /\ watcherPending
    /\ IF ~fileExists THEN
           \* Q-M1 missing-file delete guard: missing chapter file never pushes deletes
           /\ watcherPending' = FALSE
           /\ IF BUG_MODE = "missing_file_pushes_delete" THEN
                  pushedDeletes' = pushedDeletes \cup loadedBlockIDs
              ELSE
                  UNCHANGED pushedDeletes
           /\ UNCHANGED <<diskVars, sessionBlocks, writtenBlocks, lastWrittenUserSlices,
                          hasLastWritten, loadedBlockIDs, readerDirty,
                          extUnseenEdit, conflictBlocks, explicitDeletes,
                          spuriousEchoMerge, ops>>
       ELSE IF IsOwnWrite THEN
           \* Own-write echo suppression (VaultSync.isOwnWrite)
           /\ watcherPending' = FALSE
           /\ IF BUG_MODE = "ignore_is_own_write" THEN
                  spuriousEchoMerge' = TRUE
              ELSE
                  UNCHANGED spuriousEchoMerge
           /\ UNCHANGED <<diskVars, sessionBlocks, writtenBlocks, lastWrittenUserSlices,
                          hasLastWritten, loadedBlockIDs, readerDirty,
                          extUnseenEdit, conflictBlocks, explicitDeletes, pushedDeletes, ops>>
       ELSE
           \* External edit detected -> VaultSync.applyExternal 3-way merge
           LET merged == [b \in BLOCK_IDS |-> MergedBlock(b)]
               newConflicts == {b \in BLOCK_IDS : IsBlockConflict(b)}
           IN
           /\ diskBlocks' = merged
           /\ sessionBlocks' = merged
           /\ writtenBlocks' = merged
           /\ lastWrittenUserSlices' = diskUserSlices
           /\ hasLastWritten' = TRUE
           /\ loadedBlockIDs' = {b \in BLOCK_IDS : merged[b] # {}}
           /\ readerDirty' = FALSE
           /\ watcherPending' = FALSE
           /\ extUnseenEdit' = [b \in BLOCK_IDS |-> "none"]
           /\ conflictBlocks' = conflictBlocks \cup newConflicts
           /\ UNCHANGED <<fileExists, diskUserSlices, expectedUserSlices,
                          explicitDeletes, pushedDeletes, spuriousEchoMerge, ops>>

\* Terminal quiescent step ONLY when all bounded edits, flushes, and watcher events are drained
Quiescent ==
    /\ ops = MAX_OPS
    /\ ~watcherPending
    /\ ~(fileExists /\ readerDirty)
    /\ UNCHANGED vars

-----------------------------------------------------------------------------
Next ==
    \/ \E b \in BLOCK_IDS, v \in VALUES : ReaderEditBlock(b, v)
    \/ \E b \in BLOCK_IDS : ReaderRemoveBlock(b)
    \/ ReaderFlush
    \/ \E s \in SLOTS, u \in USER_TEXTS : ObsidianEditUserText(s, u)
    \/ \E b \in BLOCK_IDS, v \in VALUES : ObsidianEditOwnedBlock(b, v)
    \/ ObsidianDeleteOrRenameFile
    \/ ObsidianRestoreFile
    \/ WatcherFire
    \/ Quiescent

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Safety invariants

TypeOK ==
    /\ fileExists \in BOOLEAN
    /\ diskUserSlices \in [SLOTS -> USER_TEXTS]
    /\ expectedUserSlices \in [SLOTS -> USER_TEXTS]
    /\ diskBlocks \in [BLOCK_IDS -> BODY_SETS]
    /\ sessionBlocks \in [BLOCK_IDS -> BODY_SETS]
    /\ writtenBlocks \in [BLOCK_IDS -> BODY_SETS]
    /\ lastWrittenUserSlices \in [SLOTS -> USER_TEXTS]
    /\ hasLastWritten \in BOOLEAN
    /\ loadedBlockIDs \subseteq BLOCK_IDS
    /\ readerDirty \in BOOLEAN
    /\ watcherPending \in BOOLEAN
    /\ extUnseenEdit \in [BLOCK_IDS -> OPT_VAL]
    /\ conflictBlocks \subseteq BLOCK_IDS
    /\ explicitDeletes \subseteq BLOCK_IDS
    /\ pushedDeletes \subseteq BLOCK_IDS
    /\ spuriousEchoMerge \in BOOLEAN
    /\ ops \in 0..MAX_OPS

\* Every user-authored Markdown slice outside Reader markers stays byte-for-byte
UserTextByteInvariant ==
    fileExists => (diskUserSlices = expectedUserSlices)

\* Concurrent external edit inside an owned block is never silently overwritten;
\* both bodies are preserved until reconciled via VaultSync.applyExternal.
NoSilentClobberOnConcurrentEdit ==
    fileExists =>
        \A b \in BLOCK_IDS :
            extUnseenEdit[b] # "none" => extUnseenEdit[b] \in diskBlocks[b]

\* Q-M1: A missing or renamed chapter .md file never pushes sync deletes
MissingFileNeverPushesDeletes ==
    pushedDeletes \subseteq explicitDeletes

\* Reader's own writes are recognized by VaultSync.isOwnWrite and ignored as echoes
OwnWriteEchoIgnored ==
    ~spuriousEchoMerge

=============================================================================
