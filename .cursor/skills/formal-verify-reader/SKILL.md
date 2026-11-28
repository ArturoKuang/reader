---
name: formal-verify-reader
description: Run and maintain Reader's TLA+ formal verification suite, canary proofs, property-based Swift/TypeScript harnesses, and formal drift checks covering Mac/Phone client sync, Obsidian vault owned-block merge, and self-updater swap/rollback.
---

# Formal Verification Skill — Reader (`ArturoKuang/reader`)

Use this skill whenever touching client sync (`Packages/ReaderSync`, `apps/mobile/src/sync`, `App/Reader/Sync`), Obsidian vault owned-block merging (`Packages/ReaderCore/{OwnedBlocks,VaultSync,Annotations}.swift`, `App/Reader/VaultCoordinator.swift`), or the macOS self-updater (`Packages/ReaderCore/Sources/ReaderCore/Updater.swift`, `App/Reader/Updater/AppUpdater.swift`), or when investigating concurrency, data-loss, conflict-resolution, or update-safety bugs.

## How This Complements Smoke / UI Verification

- **Smoke / UI verification (`Scripts/smoke-test.sh`)** verifies that `ReaderCore` and `ReaderSync` unit tests pass, `Reader.app` builds cleanly via `xcodebuild`, and the built app launches in isolation against a throwaway PDF without touching user data.
- **Formal verification (`./Scripts/formal-verify.sh`, this skill)** exhaustively checks **all reachable interleavings** of concurrent sync operations, dropped responses, server rebuilds, `disk_full` faults, concurrent Obsidian file edits, and mid-swap updater failures using TLA+/TLC (with deadlock checking, liveness, and negative canary proofs) plus randomized Swift & TypeScript property harnesses.

Run **both** when changing core sync, vault, or updater logic.

## Coverage Map (`sync_commit: 82f73bd`)

Synced to commit `82f73bd9864eb93dfe58d50a33ed68d74e647a1a` (manifest: `formal/manifest.json`).

### TLA+ Models (Gate G1)

| Model | Spec & Configs | Covered Source Files | Covered Symbols |
| --- | --- | --- | --- |
| `ReaderClientSync` | `formal/tla/ReaderClientSync.tla`<br>`ReaderClientSync.cfg` / `_Deep.cfg` / `_Canary.cfg` | `Packages/ReaderSync/Sources/ReaderSync/SyncEngine.swift`<br>`Packages/ReaderSync/Sources/ReaderSync/SyncStore.swift`<br>`Packages/ReaderSync/Sources/ReaderSync/ConflictResolution.swift`<br>`apps/mobile/src/sync/engine.ts`<br>`App/Reader/Sync/SyncController.swift` | `SyncEngine.enqueueLocalRecords`, `pushOutbox`, `pullAll`, `resolve(conflict:choice:)`, `uploadBook`; `SyncStore.mergeOutbox`, `upsertRecord`, `markClean`, `resetForNewServer`; `ConflictResolution.prepare`, `currentHeadVersion`; `SyncController.applyOpeningPosition`; mobile `stage`, `enqueue`, `coalesce`, `flushOnce`, `applyPush`, `applyPulledPage`, `pull`, `openBook`, `uploadBook`, `resetForNewServer` |
| `VaultOwnedBlocks` | `formal/tla/VaultOwnedBlocks.tla`<br>`VaultOwnedBlocks.cfg` / `_Deep.cfg` / `_Canary.cfg` | `Packages/ReaderCore/Sources/ReaderCore/OwnedBlocks.swift`<br>`Packages/ReaderCore/Sources/ReaderCore/VaultSync.swift`<br>`Packages/ReaderCore/Sources/ReaderCore/Annotations.swift`<br>`App/Reader/VaultCoordinator.swift` | `OwnedBlocks.parse`, `render`, `body`, `upsert`, `remove`; `VaultSync.applyExternal`, `isOwnWrite`; `VaultAnnotationSync.render`; `VaultCoordinator.reload`, `mergeExternal`, `writeNotes`, `writeIfChanged`, `flush` |
| `AppUpdaterStateMachine` | `formal/tla/AppUpdaterStateMachine.tla`<br>`AppUpdaterStateMachine.cfg` / `_Deep.cfg` / `_Canary.cfg` | `Packages/ReaderCore/Sources/ReaderCore/Updater.swift`<br>`App/Reader/Updater/AppUpdater.swift` | `AppBuildInfo.isDev`, `UpdateEvaluator.parseManifest`, `UpdateEvaluator.evaluate`, `UpdateSwapScript.build`; `AppUpdater.checkForUpdates`, `verifySignature`, `stageUpdateInBackground`, `downloadAndStage`, `sha256Hex`, `validateAppBundle`, `installUpdate`, `applyStagedUpdateOnQuitIfNeeded`, `launchSwap` |

### Code Property Harnesses (Gate G2)

| Harness | Path | Covered Files |
| --- | --- | --- |
| `ReaderCoreFormalPropertyTests` | `Packages/ReaderCore/Tests/ReaderCoreTests/FormalPropertyTests.swift` | `OwnedBlocks.swift`, `VaultSync.swift`, `Annotations.swift`, `Updater.swift` |
| `ReaderSyncFormalHarnessTests` | `Packages/ReaderSync/Tests/ReaderSyncTests/FormalSyncHarnessTests.swift` | `SyncEngine.swift`, `SyncStore.swift`, `ConflictResolution.swift`, `SyncStatus.swift` |
| `MobileSyncFormalTests` | `apps/mobile/src/formal/syncFormal.test.ts` | `apps/mobile/src/sync/engine.ts`, `storage.ts`, `status.ts` |

## Commands

### Full Formal Verification Gate

Runs **G0** (static analysis + code-quality ratchet), **G1** (TLC standard models + negative canaries), **G2** (Swift & mobile formal property harnesses), and **G3** (anti-cheat & manifest drift guard):

```bash
./Scripts/formal-verify.sh
```

Deep nightly/pre-release sweep (wider TLC bounds via `*_Deep.cfg` and `FORMAL_CASES=1000`):

```bash
./Scripts/formal-verify.sh --mode deep
```

Single-model run via the unified harness (runs both standard/deep and canary):

```bash
./Scripts/formal-verify.sh --model ReaderClientSync --skip-code --skip-static
```

Install local git pre-commit / pre-push verification hooks:

```bash
./Scripts/install-hooks.sh
```

Check whether covered source files drifted since `sync_commit` in `formal/manifest.json`:

```bash
./Scripts/check-formal-drift.sh
```

### Single-Model TLC Commands (Standard, Deep, Canary)

```bash
JAVA=/opt/homebrew/opt/openjdk@21/bin/java
JAR=$HOME/ci/tools/tla2tools.jar

# Standard (must EXIT 0 with zero errors)
META=$(mktemp -d /tmp/tlc-rd-XXXXXX)
"$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -cleanup -metadir "$META" \
  -config formal/tla/ReaderClientSync.cfg formal/tla/ReaderClientSync.tla
rm -rf "$META"

# Deep (must EXIT 0 with zero errors)
META=$(mktemp -d /tmp/tlc-rd-XXXXXX)
"$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -cleanup -metadir "$META" \
  -config formal/tla/ReaderClientSync_Deep.cfg formal/tla/ReaderClientSync.tla
rm -rf "$META"

# Canary (must EXIT non-zero with expected invariant violation!)
META=$(mktemp -d /tmp/tlc-rd-XXXXXX)
"$JAVA" -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers 2 -cleanup -metadir "$META" \
  -config formal/tla/ReaderClientSync_Canary.cfg formal/tla/ReaderClientSync.tla
rm -rf "$META"
```

Substitute `VaultOwnedBlocks` or `AppUpdaterStateMachine` in place of `ReaderClientSync` to check the other two models individually.

## Properties & Harms (Plain English)

### `ReaderClientSync`
- **`OutboxUniquePerKey`**: Every client's outbox holds at most one pending mutation per record key (`SyncStore.mergeOutbox` / `engine.ts:coalesce`). *Harm if broken:* duplicate pushes, spurious conflicts, unbounded offline queue growth.
- **`DirtyRecordNeverOverwrittenByPull`**: Pulling remote changes never overwrites an unpushed local edit in the outbox. *Harm if broken:* offline highlights and notes vanish silently when a pull arrives before push drains.
- **`CursorMonotonicWithinServer`**: Within one `serverId`, pull cursors never go backward and never exceed `serverSeq`. *Harm if broken:* skipped remote changes or infinite re-pull churn.
- **`ResolvedVersionMatchesServerHead`**: After Mac resolves a conflict, Mac stores the server's new head version (`headVersion + 1`), not `conflict.baseVersion + 1`. *Harm if broken:* next Mac edit pushes a stale `baseVersion` and opens a spurious second conflict.
- **`MidSessionPositionNeverJumps`**: Remote reading positions are stored on pull and only applied when opening a book. *Harm if broken:* active reading page jumps mid-session while the user is reading.
- **`DiskFullNeverBlocksRecordSync`**: HTTP 507 `disk_full` / `quota_exceeded` pauses book blob uploads without blocking record push/pull. *Harm if broken:* a full sync disk silently freezes all highlight/note/word sync.
- **`EventualConvergence` (liveness)**: Once finite edits and faults stop, Mac and Phone converge to identical server head values, versions, and cursors — even if `serverDiskFull` remains true. *Harm if broken:* permanent split-brain between Mac and Phone while showing "Synced".

### `VaultOwnedBlocks`
- **`UserTextByteInvariant`**: User-authored Markdown slices outside `<!-- reader:begin ... --> ... <!-- reader:end -->` stay byte-for-byte unchanged across all Reader writes and merges. *Harm if broken:* Reader corrupts or deletes a user's handwritten Obsidian prose.
- **`NoSilentClobberOnConcurrentEdit`**: Concurrent Obsidian edits inside an owned block are never silently overwritten by Reader; 3-way merge (`VaultSync.applyExternal`) preserves both bodies with a warning callout. *Harm if broken:* Obsidian edits vanish silently during a flush/watcher race.
- **`MissingFileNeverPushesDeletes`**: Q-M1 guard — deleting or renaming a chapter `.md` file externally never pushes delete tombstones to sync. *Harm if broken:* reorganizing vault files in Obsidian wipes highlights across paired devices.
- **`OwnWriteEchoIgnored`**: Watcher events matching `lastWritten` are ignored via `VaultSync.isOwnWrite`. *Harm if broken:* feedback loops and spurious conflict callouts on Reader's own saves.

### `AppUpdaterStateMachine`
- **`NoUnverifiedInstall`**: No candidate archive can reach `ready_to_install` or replace `TARGET` without passing Ed25519 signature verification, schema/channel/URL-prefix policy checks, SHA-256 digest verification, and bundle/codesign validation. *Harm if broken:* tampered or corrupt archive overwrites `Reader.app`.
- **`NoSilentDowngrade`**: Production builds reject lower `buildNumber` or identical `(buildNumber, commitSHA)`; dev builds reject background upgrades unless manually triggered. *Harm if broken:* signed-manifest replay downgrades users or overwrites local dev builds.
- **`RollbackPreservesRunnableApp`**: Every swap step keeps a valid bundle in `TARGET` or `BACKUP`; failed `mv`/`ditto` or `open -n` restores `BACKUP` to `TARGET` and removes `BACKUP`. *Harm if broken:* interrupted update leaves user with a missing or broken `Reader.app`.
- **`StagedSwapTerminatesCleanly` (liveness)**: Once spawned, the swap script always finishes cleanly in `done_installed` or `done_rolled_back`. *Harm if broken:* hung update leaving `Reader.app` stranded in `.Reader.app.backup`.

## Bounds, Assumptions, and Explicit Non-Goals

- **Bounds**: TLC explores finite bounded domains (see `formal/manifest.json` `bounds` for Standard vs Deep constants). Deep configs widen multi-fault interleavings (`MAX_FAULTS = 3`), edit depth (`MAX_OPS = 4`), and candidate build/commit matrices.
- **Assumptions**:
  - SQLite transactions in `SyncStore` and atomic file writes (`write(..., atomically: true)`) provide single-operation atomicity.
  - Apple CryptoKit Ed25519 and SHA-256 primitives are cryptographically sound.
  - Under fairness for liveness, network outages and retries eventually deliver pushes/pulls once finite faults stop.
- **Explicit Non-Goals**:
  - TailDrive sync server internals, pairing QR cryptography, and resumable blob byte-range chunking.
  - macOS Gatekeeper/notarization internals or adversarial OS-level deletion of `BACKUP` during swap execution.
  - UI rendering, PDF/EPUB layout geometry, and AI tutor prompts.

## Known Real-Code Findings (at `82f73bd`)

**Golden rule: findings stay findings.** Never weaken an invariant to make a buggy implementation pass. At `sync_commit: 82f73bd`, the real codebase has six verified defects documented in `formal/README.md`:

1. `SyncEngine.swift:198-223` — `SyncEngine.resolve` discards `api.resolve`'s returned `version` and stores `conflict.baseVersion + 1` instead of `headVersion + 1` (`BUG_MODE = "resolve_uses_conflict_base"` violates `ResolvedVersionMatchesServerHead`).
2. `apps/mobile/src/sync/engine.ts:626-627, 766-784` — Phone leaves `record.dirty = true` on `heldGeneration` conflicts so `applyEnvelope` skips Mac's resolution while clearing the conflict badge (`BUG_MODE = "phone_held_stays_dirty_on_resolve"` violates `EventualConvergence`).
3. `SyncEngine.swift:446-461` & `apps/mobile/src/sync/engine.ts:502-503, 784` — **TLC-discovered**: advancing `cursor` past a skipped dirty envelope causes permanent missed updates if the pending push later replays idempotently from a dropped response (`BUG_MODE = "cursor_skips_dirty"` violates `EventualConvergence`).
4. `SyncEngine.swift:434-439` & `SyncStore.swift:473-482` — `pullAll` mid-pull `serverId` reset forgets to update `health.serverId` (infinite reset loop), and `resetForNewServer()` omits `DELETE FROM books;`.
5. `App/Reader/VaultCoordinator.swift:255-282, 309-316` — `writeNotes` overwrites disk via `VaultAnnotationSync.render` without calling `VaultSync.applyExternal`, clobbering concurrent Obsidian edits within the watcher debounce window (`BUG_MODE = "clobber_external_edit"` violates `NoSilentClobberOnConcurrentEdit`); `writeIfChanged` resets `applyingOwnWrite = false` immediately; `reload(mergePending: true)` drops `session.highlights` when a chapter file disappears.
6. `SyncEngine.swift:70, 391-399` — Mac `pushOutbox` marks records clean without a per-record generation guard against concurrent edits while `await api.push` is in flight (`lock` is unused).

## Distinguishing Real Bugs vs Spec Drift

When TLC or a formal property harness fails:

1. **Read the counterexample trace step by step** and map each TLA+ action back to the exact Swift/TypeScript lines in the coverage table above.
2. **Try to reproduce the trace in real code** (unit test or mental execution against the covered functions):
   - **If the real code exhibits the bad trace** -> **REAL BUG**. Do NOT weaken the TLA+ invariant! Fix the production code (or file/record the finding and add a regression test in the Gate G2 harness), then re-run `./Scripts/formal-verify.sh`.
   - **If the real code prevents that transition** (e.g., an added lock, guard, or changed protocol contract that the TLA+ action did not model) -> **SPEC DRIFT**. Update the TLA+ action faithfully to match the real code, verify that the canary config STILL fails, update `formal/manifest.json` (`sync_commit`, `covered_files`, `covered_symbols`), and re-run `./Scripts/formal-verify.sh`.
3. **Never silence a canary**: if a `_Canary.cfg` passes (`EXIT 0`), either the invariant became vacuous or the bug branch became unreachable — treat a passing canary as a critical verification failure.

## Maintenance Loop

Whenever `./Scripts/check-formal-drift.sh` flags changes to covered files or after fixing any of the known findings above:

1. Run `/maintain-formal-verification-skill` (or review `git diff <sync_commit>..HEAD -- <covered_files>`).
2. Update affected TLA+ actions/invariants, code harnesses, and canary proofs while preserving true-to-code fidelity.
3. Run `./Scripts/formal-verify.sh --mode deep` and verify all standard + deep models pass and all canaries fail on their expected invariants.
4. Update `sync_commit` in `formal/manifest.json`, `formal/README.md`, and this `SKILL.md` to the new HEAD commit.
