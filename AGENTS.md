This codebase is yours: what it's for and how it's built are your call, and you'll keep building on it.

# Working in this repo

Reader is a native macOS app for reading PDF, EPUB, and Markdown, with notes, looked-up words, highlights, marks, Read Aloud, and AI questions. Notes are stored as Markdown next to the book (a `.reader` package) or inside an Obsidian vault. A phone companion app (Expo) and a Mac sync client talk to a sync server on the user's Mac mini. The server lives in another repository.

`README.md` describes features and the on-disk formats for people. This file is how to change the code safely. Read both before a large change.

## Map

| Path | What it is | How it is checked |
| --- | --- | --- |
| `App/Reader/` | AppKit + SwiftUI shell: windows, `PDFView`, `WKWebView`, menus, TTS UI, sync UI, updater UI | `Scripts/check.sh app` (compile), then run it (see "Seeing the app") |
| `Packages/ReaderCore/` | All pure logic: sidecar and vault formats, anchors and re-anchoring, EPUB/ZIP/CFI, Markdown parse and render, words, marks, AI requests and `claude`/`codex` argv, TTS planning, update manifests. Foundation only | `swift test` (~15 s) |
| `Packages/ReaderSync/` | Mac sync client: SQLite outbox, HTTP client for the TailDrive `/v1/reader` API, conflict resolution, QR pairing | `swift test` (~20 s; the live test skips) |
| `Packages/ReaderKokoro/` | Re-exports FluidAudio (Kokoro TTS model). No code of its own | Built by the app check |
| `apps/mobile/` | Expo / React Native phone app (Android first, iOS Simulator works) | `tsc`, `tsx --test`, `jest`, `expo lint` |
| `docs/sync-design/` | Sync spec (`SYNC_SPEC.md`), `openapi.yaml`, JSON schemas, fixtures, and the Python tools that make and validate them | `Scripts/check.sh spec` |
| `spec/tokens.json` | Design tokens shared by Mac and phone (highlight palette, sync chip) | Mirrors in code; see Invariants |
| `Scripts/` | `check.sh` (all checks), `smoke-test.sh` (isolated launch), packaging, release signing, installer, live sync test | — |
| `project.yml` | XcodeGen spec. `Reader.xcodeproj` is generated from it, gitignored, and never hand-edited | — |

### Where to change what

- **Sidecar files** (`notes.md`, `highlights.md`, `words.md`, `marks.md`, `state.json`): `ReaderCore/Sidecar.swift`, `MarkdownDocuments.swift`, `JSONValue.swift` (`ReaderComment`), `Annotations.swift`, `Models.swift`.
- **Anchoring and re-anchoring**: `Reanchor.swift`, `EPUBCFI.swift`. EPUB reading: `EPUB.swift`, `ZipArchive.swift`.
- **Obsidian vault mode**: `Vault.swift`, `VaultNotes.swift`, `VaultSync.swift`, `OwnedBlocks.swift`, `VocabularyFile.swift`, `Concepts.swift`, `Tutor.swift`. App side: `App/Reader/VaultCoordinator.swift`.
- **Words, lookups, export**: `Words.swift`. **Marks and Back/Forward**: `Marks.swift`. **Find**: `FindSelection.swift`.
- **AI providers, prompts, CLI flags**: `AI.swift`, `Prompt.swift`, `Tutor.swift`. The exact `claude`/`codex` argument lists are asserted in `CoreTests.swift`.
- **Markdown as a document**: `MarkdownParser.swift`, `MarkdownModel.swift`, `MarkdownHTMLRenderer.swift`, `MarkdownStyles.swift`, `MarkdownWikiLinkResolver.swift`, `SyntaxHighlighter.swift`, `LaTeXMathRenderer.swift`. App side: `WebDocumentContainerViewController.swift`, `LocalAssetSchemeHandler.swift`, `MarkdownFileWatcher.swift`.
- **Read Aloud**: core `TTSModels.swift`, `TTSTextPlanner.swift`, `KokoroTTS.swift`. App `TTSEngine.swift`, `TTSPlayerView.swift`, `TTSBridge.swift`, `KokoroEngineService.swift`, `PDFTTSOverlay.swift`, `WebTTSScript.swift`, `*+TTS.swift`.
- **Window and document**: `ReaderDocument.swift` (`NSDocument`), `ReaderSession.swift` (one open book's state and actions), `ReaderWindowController.swift`, `PDFContainerViewController.swift`, `PaneHostController.swift` (side-by-side panes), `Views.swift` (SwiftUI sidebar, inspector, welcome). Menus and shortcuts: `AppDelegate.buildMenu()`.
- **Selection UI**: `SelectionBar.swift`, `NotePopover.swift`, `HighlightContextMenu.swift`, `AnnotationBrowser.swift`.
- **Sync**: `Packages/ReaderSync`, `App/Reader/Sync/`, phone `apps/mobile/src/sync/`, contract in `docs/sync-design/spec/`.
- **Updates and releases**: `ReaderCore/Updater.swift`, `App/Reader/Updater/`, `Scripts/package-macos.sh`, `Scripts/sign-manifest.swift`, `Scripts/install-macos-app.sh`, `.github/workflows/release-main.yml`.

## Checks

One command picks the checks from the files you changed relative to `origin/main`:

```bash
Scripts/check.sh            # auto
Scripts/check.sh all        # everything
Scripts/check.sh core app   # only these
```

| Check | Runs | Picked by changes under |
| --- | --- | --- |
| `core` | `swift test` in `Packages/ReaderCore` | `Packages/ReaderCore/`, `spec/` |
| `sync` | `swift test` in `Packages/ReaderSync` | `Packages/ReaderCore/`, `Packages/ReaderSync/` |
| `mobile` | `npm run typecheck`, `npm test`, `npm run lint` in `apps/mobile` | `apps/mobile/`, `spec/` |
| `spec` | `validate.py`, plus "committed schemas equal `make_schemas.py` output" | `docs/sync-design/` |
| `app` | `xcodegen generate` + Debug `xcodebuild` into `build/` (~40 s clean) | `App/`, `project.yml`, any Swift package |

It prints one line per check and only the error lines of a failure. Full logs go to `$TMPDIR/reader-check/`. A check whose tools are missing shows `SKIP … not verified`. That is not a pass, so say so in your report.

Setup the checks need:

- Xcode (Swift 5.9+; the TTS package needs Swift 6.2 and macOS 15) and `brew install xcodegen`.
- `npm ci --prefix apps/mobile` once, for `mobile`.
- For `spec`: `pip install jsonschema referencing openapi-spec-validator pyyaml`, or point `READER_SPEC_PYTHON` at a venv's `python` that has them.

**From a sandboxed agent shell** (Claude Code, Codex, and other macOS Seatbelt sandboxes): SwiftPM, `xcodebuild`, and `tsx` cannot run inside the sandbox. SwiftPM fails with `sandbox-exec: sandbox_apply: Operation not permitted` or `You don't have permission to save the file "output-file-map.json"`. `tsx` fails with `listen EPERM`. Those are sandbox failures, not code failures, and `check.sh` reports them as such. Run it with the sandbox off. If `npm ci` fails with `EPERM` on `~/.npm`, add `--cache "$TMPDIR/npm-cache"`.

A change is done when `Scripts/check.sh` passes, new logic in `ReaderCore` or `ReaderSync` has tests, and a UI change has been seen running.

## Seeing the app

There is no CLI, debug port, or UI test target. The app has no accessibility identifiers. The stable handles are the menu titles and key equivalents in `AppDelegate.buildMenu()`.

- `Scripts/smoke-test.sh` (~50 s) runs both Swift test suites, a Debug build, and an isolated launch against a generated PDF, then cleans up. Use it to prove the app still starts.
- To launch by hand, copy its isolation: a unique `PRODUCT_BUNDLE_IDENTIFIER`, `CFFIXED_USER_HOME`, `READER_QA_SUPPORT`, and `READER_QA_CACHES` pointing into a scratch folder, and `-ApplePersistenceIgnoreState YES`. Without them, the build shares the user's library index, global marks, settings, and saved window state.
- Never use `open -a Reader` or `open 'reader://…'`. LaunchServices can hand them to the user's own running Reader.
- Proof of a feature is the sidecar file on disk after ⌘S, plus an unchanged `shasum` of the book. A toast or screenshot alone is not proof.
- AI features have no mock. API providers use the user's keychain keys, and CLI providers run the real `claude`/`codex`. Both cost money, so do not run them without the user's OK. Report them as unverified otherwise.

## Invariants

- **Never write to the book file.** Highlights, rotation, bookmarks, and notes live in the sidecar, vault, or `state.json`. Changing the book's bytes changes its fingerprint and makes every entry re-anchor.
- **The sidecar format is a user-facing contract.** Each entry carries one `<!-- reader {sorted compact JSON} -->` comment; unknown keys round-trip through `extras`; a block without a comment is ignored and reported. If you change a field, update `README.md`, `docs/sync-design/spec/markdown-mapping.md`, `apps/mobile/src/contract/sidecar.ts`, and the round-trip tests together.
- **Vault mode edits only blocks Reader owns** (`<!-- reader:begin id=… -->` … `<!-- reader:end -->`). Hand-written text stays byte for byte. Concept stubs are never overwritten. External edits win when only one side changed; when both changed, both copies are kept.
- **Highlight colors are numbers 1–6 in a fixed order.** `HighlightPalette` in `ReaderCore/Models.swift`, `spec/tokens.json`, and `apps/mobile/src/ui/tokens.ts` must agree.
- **Word ids** are `w_` + `trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`, with no Unicode normalization. Vectors live in `docs/sync-design/spec/fixtures/word-id/normalize.json` and `apps/mobile/src/contract/fixtures/word-id-normalize.json`.
- **ReaderCore imports only Foundation** (plus zlib), never AppKit, PDFKit, or SwiftUI, so its tests run without the app.
- **The app is not sandboxed and must stay that way.** It runs `claude`/`codex` and writes next to books in any folder. The hardened runtime stays on.
- **CLI runs stay read-only.** `claude` gets `--tools Read,Grep,Glob` and `--permission-mode dontAsk`; `codex exec` gets `--sandbox read-only`. Do not add `--dangerously-skip-permissions`. Vault tutoring is the one exception: it may write only `learner/`, `learning/`, and `reviews/`.
- **Phone types are hand-written copies** of the Swift models (`apps/mobile/src/contract/`, `apps/mobile/src/sync/wire.ts`). Change Swift and TypeScript in the same change.
- **The JSON schemas are generated.** Edit `docs/sync-design/tools/make_schemas.py`, run it, then run `validate.py`. Never hand-edit `spec/schemas/*.json`.

## Things that reach outside the repo (ask the user first)

- **Merging to `main` ships to the user's Mac.** `.github/workflows/release-main.yml` runs on every push to `main` that touches anything except `**/*.md`, `spec/**`, or `apps/mobile/**`. It builds, signs, and publishes `main-<N>`, then moves `main-latest`. The installed app checks `main-latest` in the background, stages the update, and swaps it in silently on quit. Work on a branch and open a PR. Do not push to `main` or move release tags.
- `Scripts/live-taildrive-sync.sh` (`READER_SYNC_LIVE=1`) talks to the real sync test server on the Mac mini (`127.0.0.1:8789/v1/reader`).
- `Scripts/install-macos-app.sh` quits the running Reader and replaces `~/Applications/Reader.app`.
- The user's own Reader is often running. Never drive, focus, or kill it (`pkill Reader` is off-limits). Their data is in `~/Library/Application Support/Reader/` and in the login keychain (`com.reader.Reader`, accounts `openai` and `anthropic`).
- The update-signing public key is pinned in `AppUpdater.swift`, `install-macos-app.sh`, and the workflow. Changing it breaks updates for every installed copy.

## Conventions

- Commit subjects are one imperative sentence: `Add …`, `Fix …`, `Polish …`. Branches are `feat/…` or similar, merged into `main` through a PR.
- Swift: 4-space indent, no formatter or linter configured. Match the surrounding file. Put testable logic in `ReaderCore` and test it with XCTest. `MemoryFileSystem` in `Tests/ReaderCoreTests/Support.swift` fakes the disk.
- Mobile: `*.test.ts` files run under `tsx --test` (Node's runner), `*.jest.ts` under Jest in Node, `*.jest.tsx` under `jest-expo`. Maestro flows in `apps/mobile/.maestro/` need an emulator.
- Keep `README.md` true when behavior or a file format changes. It is the user's spec for the formats.

## Known drift

- `docs/sync-design/SYNC_SPEC.md` was written for the server project. Its `Packages/SyncServer/` and `spec/gen.sh` are not in this repo, and its `spec/…` paths mean `docs/sync-design/spec/…` here. The client in this repo follows the TailDrive rev 3.2 API (`TailDriveAPI.swift`, `apps/mobile/src/sync/NETWORK.md`).
- The phone's contract types are still hand-written. No codegen from the schemas exists yet.
