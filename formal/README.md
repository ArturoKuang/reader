# Reader Formal Verification Suite

Machine-checked TLA+ specifications and property-based code harnesses for the concurrency, data-preservation, and self-update invariants in `ArturoKuang/reader` (synced to commit `82f73bd9864eb93dfe58d50a33ed68d74e647a1a`).

## Models

| Model | Spec | Standard | Deep | Canary (`BUG_MODE`) | Expected Canary Violation |
| --- | --- | --- | --- | --- | --- |
| `ReaderClientSync` | `formal/tla/ReaderClientSync.tla` | `ReaderClientSync.cfg` | `ReaderClientSync_Deep.cfg` | `ReaderClientSync_Canary.cfg` (`pull_overwrites_dirty`) | `DirtyRecordNeverOverwrittenByPull` |
| `VaultOwnedBlocks` | `formal/tla/VaultOwnedBlocks.tla` | `VaultOwnedBlocks.cfg` | `VaultOwnedBlocks_Deep.cfg` | `VaultOwnedBlocks_Canary.cfg` (`clobber_external_edit`) | `NoSilentClobberOnConcurrentEdit` |
| `AppUpdaterStateMachine` | `formal/tla/AppUpdaterStateMachine.tla` | `AppUpdaterStateMachine.cfg` | `AppUpdaterStateMachine_Deep.cfg` | `AppUpdaterStateMachine_Canary.cfg` (`skip_rollback_on_swap_fail`) | `RollbackPreservesRunnableApp` |

Every model is verified with deadlock checking enabled and includes at least one negative canary proving its invariants can fail.

### Properties Checked

- **`ReaderClientSync`** (`SyncEngine.swift`, `SyncStore.swift`, `ConflictResolution.swift`, `apps/mobile/src/sync/engine.ts`, `SyncController.swift`):
  - Safety: `TypeOK`, `OutboxUniquePerKey`, `DirtyRecordNeverOverwrittenByPull`, `CursorMonotonicWithinServer`, `ResolvedVersionMatchesServerHead`, `MidSessionPositionNeverJumps`, `DiskFullNeverBlocksRecordSync`.
  - Liveness: `EventualConvergence` (`<>[]Converged`) under weak fairness once finite edits/resets stop — including while `serverDiskFull = TRUE` and book uploads remain paused.
- **`VaultOwnedBlocks`** (`OwnedBlocks.swift`, `VaultSync.swift`, `Annotations.swift`, `VaultCoordinator.swift`):
  - Safety: `TypeOK`, `UserTextByteInvariant`, `NoSilentClobberOnConcurrentEdit`, `MissingFileNeverPushesDeletes`, `OwnWriteEchoIgnored`.
- **`AppUpdaterStateMachine`** (`Updater.swift`, `AppUpdater.swift`):
  - Safety: `TypeOK`, `NoUnverifiedInstall`, `NoSilentDowngrade`, `RollbackPreservesRunnableApp`.
  - Liveness: `StagedSwapTerminatesCleanly` (`(phase = "swap_wait_exit") ~> (phase \in {"done_installed", "done_rolled_back"})`).

## Bounds

- **`ReaderClientSync`**:
  - Standard: 2 clients (`mac`, `phone`), 1 record key, 2 payload values, 2 reading positions, `MAX_EDITS = 2`, `MAX_POS_EDITS = 1`, `MAX_DROPS = 1`, `MAX_RESETS = 1`, `MAX_DISK_EVENTS = 1`, `MAX_FAULTS = 1`.
  - Deep: widens combined fault budget to `MAX_FAULTS = 3` so dropped push responses, server rebuilds, and `disk_full` book pauses all interact within the same trace.
- **`VaultOwnedBlocks`**:
  - Standard: 2 owned block IDs, 3 body values, 2 user-text values across 2 slices, `MAX_OPS = 3`.
  - Deep: `MAX_OPS = 4`.
- **`AppUpdaterStateMachine`**:
  - Standard: 3 builds (`INIT_BUILD = 2`), 2 commits, 2 channels (`main`, `beta`), 2 schema versions (`1`, `2`), both production and dev initial states, manual and background checks, install-now and swap-on-quit paths.
  - Deep: 4 builds, 3 commits.

## Running Verification

Full verification gate (G0 static analysis + code-quality ratchet, G1 TLC models + canaries, G2 Swift/mobile formal property harnesses, G3 anti-cheat/drift guard):

```bash
./Scripts/formal-verify.sh
./Scripts/formal-verify.sh --mode deep
./Scripts/formal-verify.sh --model ReaderClientSync
```

Single-model TLC run:

```bash
JAVA=/opt/homebrew/opt/openjdk@21/bin/java
JAR=$HOME/ci/tools/tla2tools.jar
META=$(mktemp -d /tmp/tlc-rd-XXXXXX)
"$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -cleanup -metadir "$META" \
  -config formal/tla/ReaderClientSync.cfg formal/tla/ReaderClientSync.tla
rm -rf "$META"
```

Check for spec/code drift against `formal/manifest.json`:

```bash
./Scripts/check-formal-drift.sh
```

## Known Real-Code Findings (at `82f73bd`)

Following the formal-verification rule that **findings stay findings** (invariants are never weakened to hide implementation bugs), modeling the implementation surfaced these real defects in `reader` at commit `82f73bd`:

1. **`SyncEngine.resolve(conflict:choice:)` writes stale `conflict.baseVersion + 1`** (`Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:198-223`)
   - `ConflictResolution.prepare` sends `baseVersion: headVersion` so the server advances to `headVersion + 1`, and `TailDriveAPI.resolve` returns `(version, seq)`.
   - `SyncEngine.resolve` discards that return value (`_ = try await api.resolve(...)`) and writes `version: conflict.baseVersion + 1` into `SyncStore.records`. Whenever `headVersion > baseVersion` (every real conflict), Mac's local `serverVersion` lags server head; editing again before pulling pushes a stale `baseVersion` and triggers a spurious second conflict.
   - **TLC reproducer**: `ReaderClientSync.tla` with `BUG_MODE = "resolve_uses_conflict_base"` violates `ResolvedVersionMatchesServerHead` at depth 7.

2. **Phone drops Mac's conflict resolution permanently (`heldGeneration` stays `dirty = true`)** (`apps/mobile/src/sync/engine.ts:626-627, 766-784`)
   - When Phone receives a push conflict, `applyPush` sets `record.heldGeneration = record.generation` while keeping `record.dirty = true`.
   - When Mac resolves the conflict and Phone pulls the resolution envelope (`envelope.conflict == null`), `applyEnvelope` clears `this.state.conflicts` (line 767) and then hits `if (local?.dirty) return;` (line 784) without checking `local.heldGeneration === local.generation`. Phone clears the conflict badge and reports "Synced" while permanently retaining its losing local payload and stale `serverVersion`.
   - **TLC reproducer**: `ReaderClientSync.tla` with `BUG_MODE = "phone_held_stays_dirty_on_resolve"` violates `EventualConvergence` at depth 11.

3. **Advancing `cursor` past skipped dirty envelopes causes permanent missed updates after dropped-push replay** (`Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:446-461`, `apps/mobile/src/sync/engine.ts:502-503, 784`) — *discovered directly by TLC!*
   - Client A pushes `v1` (`cid=c1`); server commits `v1` (`seq=1`), but the HTTP response drops. Client B pulls `v1` and pushes `v2` (`seq=2`). Before Client A retries `c1`, Client A runs `pull()`, skips `v2` because `local.dirty == true`, yet advances `cursor := 2`. When Client A subsequently replays `c1`, the server returns the cached idempotent `{status: "applied", version: 1}`, Client A marks the record clean at `v1`, and because `cursor == 2 == serverSeq`, Client A never pulls `v2`.
   - **TLC reproducer**: `ReaderClientSync.tla` with `BUG_MODE = "cursor_skips_dirty"` violates `EventualConvergence` at depth 11.

4. **Infinite reset loop on mid-pull `serverId` change & stale `books` table** (`Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:434-439`, `SyncStore.swift:473-482`)
   - In `pullAll()`, when `page.serverId != health.serverId`, Mac calls `store.resetForNewServer()`, sets `store.serverId = page.serverId`, and `continue`s without updating `health.serverId`, re-triggering reset on every loop iteration. Additionally, `SyncStore.resetForNewServer()` deletes `records`, `outbox`, and `conflicts`, but omits `DELETE FROM books;`.

5. **`VaultCoordinator.writeNotes` can clobber concurrent Obsidian edits before watcher reload** (`App/Reader/VaultCoordinator.swift:255-282, 309-316`)
   - `writeNotes` reads disk and directly runs `VaultAnnotationSync.render` (`OwnedBlocks.upsert`) without comparing against `lastWritten[path]` or invoking `VaultSync.applyExternal`. If Obsidian edits an owned block during the 0.25s `VaultFolderWatcher` debounce window before `reload(mergePending: true)` fires and Reader flushes first, Obsidian's edit is silently overwritten.
   - Additionally, `writeIfChanged` line 315 resets `applyingOwnWrite = false` immediately (short-circuiting `holdOwnWrite()`'s 0.45s timer), and `reload(mergePending: true)` lines 168-178 preserves `session.notes` but drops `session.highlights` when a chapter `.md` file disappears.
   - **TLC reproducer**: `VaultOwnedBlocks.tla` with `BUG_MODE = "clobber_external_edit"` violates `NoSilentClobberOnConcurrentEdit` at depth 4.

6. **Mac `pushOutbox` lacks a per-record generation guard** (`Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift:70, 391-399`)
   - Unlike Phone's `record.generation === change.generation` check (`engine.ts:612`), Mac's `pushOutbox` unconditionally calls `store.markClean` / `store.upsertRecord(..., dirty: false)` after `await api.push(...)` without checking whether a newer local edit superseded the in-flight item (`SyncEngine.lock` on line 70 is also unused).
