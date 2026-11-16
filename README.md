# Reader

Reader is a native macOS app for reading PDF and EPUB. It keeps Preview’s viewing behavior — sidebar modes, continuous scroll, single page, two pages, pinch zoom — and adds a side panel for notes, looked-up words, highlights, and AI.

The app is not sandboxed. It is meant to be signed with a Developer ID and notarized for direct download, not shipped on the Mac App Store. That is what lets it launch the `claude` and `codex` command-line tools and write a notes package next to a book in any folder.

## Build and run on a Mac

You need Xcode 15 or later (macOS 14 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
open Reader.xcodeproj
```

Run the **Reader** scheme. The target is ad-hoc signed (`CODE_SIGN_IDENTITY = -`) with the hardened runtime and **no App Sandbox**, so it runs locally without a Developer ID. For distribution, sign with your Developer ID and notarize; do not turn the sandbox on.

To make Reader the default app for PDFs or EPUBs, use Finder → Get Info → Open with. The bundle declares those types as Alternate so it does not take the default away from Preview by itself.

### API keys

Open **Reader → Settings…** (⌘,).

- **ChatGPT** uses the OpenAI API. Paste an API key; it is stored in the login keychain (`com.reader.Reader`, account `openai`). The default model is `gpt-4.1`. Change it if your account uses another name.
- **Claude** uses the Anthropic API the same way (account `anthropic`). The default model is `claude-sonnet-4-5`.
- Keys are not written to `settings.json`.

ChatGPT is the default for Ask AI and for the in-context part of Look Up. Pick another provider in Settings, or just for one question in the Ask AI panel. Reader sends the book as soon as you ask. It does not show a confirmation step.

### Claude Code and Codex

Install and sign in to the tools themselves (`claude` / `claude auth`, and `codex`). Reader does not collect those logins.

Settings → **Detect installed CLIs** asks your login shell (`zsh -lic 'command -v …'`) because an app opened from the Dock does not see Homebrew’s PATH. You can also type a path by hand.

What Reader actually runs (checked against the public CLI docs, not guessed from the design draft):

```bash
claude --print --verbose --output-format stream-json \
  --permission-mode dontAsk \
  --tools Read,Grep,Glob \
  --allowedTools Read,Grep,Glob \
  -- "Answer the question in focus.md. Use book.txt for context and cite pages. Do not modify any files."

codex exec --sandbox read-only --ask-for-approval never \
  --skip-git-repo-check --ephemeral --json \
  -C "$TMP" "Answer the question in focus.md. Use book.txt for context and cite pages. Do not modify any files."
```

Why this differs from the draft:

- `--allowedTools` auto-approves tools. It does **not** limit which tools exist. `--tools` is what restricts Claude Code to Read, Grep, and Glob.
- `--print` is the long form of `-p`.
- `stream-json` requires `--verbose`, so the panel can read events as they arrive.
- `--permission-mode dontAsk` refuses anything that would pop a dialog Reader cannot answer. `--dangerously-skip-permissions` is not used.
- `--` ends the variadic tool flags so the prompt is not swallowed as another tool name.
- `codex exec` is the non-interactive command. `--ask-for-approval never` stops it waiting for a person. `--skip-git-repo-check` is required because the temp folder is not a git repo. `--ephemeral` skips session rollout files. `--json` is JSONL. `-C` is the documented short form of `--cd`. `--full-auto` is not used; current docs say it is no longer supported.

Each run gets a fresh temp folder with `book.txt` (the whole book, with page or section markers), `focus.md` (the selection and the question), and a symlink to the original file. Stop ends the process.

If a book is longer than the model’s context window, API providers get the current section in full plus passages that overlap the question, and the answer label says so. The CLI providers still receive the whole `book.txt`.

## Tests on Linux or a Mac

The storage, anchors, word list, export, prompts, and CLI argument builders live in `Packages/ReaderCore` and do not import AppKit or PDFKit.

```bash
cd Packages/ReaderCore
swift test
```

Swift 5.9 or later. On Linux the package links libz (`zlib1g-dev`).

## How a book is stored

Next to `MyBook.pdf` Reader creates `MyBook.reader`. Finder shows that folder as one package because the app exports the UTI `com.reader.sidecar` (`com.apple.package`, extension `reader`). The app id is `com.reader.Reader`.

Inside the package:

| File | Contents |
| --- | --- |
| `notes.md` | Passage notes and page notes |
| `words.md` | Lookups: word, definition, in-context explanation, every sentence |
| `highlights.md` | Colors 1–6, quote, prefix, suffix, optional PDF rects |
| `marks.md` | Lowercase (and digit / punctuation) vim marks for this book |
| `state.json` | Last page, zoom, sidebar, panel tab, rotation, bookmarks |

Every entry has a `<!-- reader {…} -->` comment with an id, a page or EPUB CFI, the quote, and a little text before and after. The comment is the machine-readable anchor; the Markdown around it is for you. An entry with no comment is ignored and reported. Deleting a block deletes it in Reader.

Each file’s front matter stores `fingerprint: sha256:…` of the book bytes, plus `pdf-id` or `epub-id` when those survive a small edit. `~/Library/Application Support/Reader/index.json` remembers where each fingerprint was last seen.

| What happened | What Reader does |
| --- | --- |
| Book and package renamed or moved together | Nothing. They stay paired. |
| Only the book was renamed | Finds the sibling package with the same fingerprint and renames it, with a banner. |
| Only the book was moved | Offers to move the package next to the book. |
| Same PDF id or EPUB id, different bytes | Updates the fingerprint (a small edit). |
| Different file entirely | Asks to re-anchor. Each entry is found again by its quote; anything left over is listed. |
| The folder cannot be written | Tries to create the package. If that fails, saves under `~/Library/Application Support/Reader/Sidecars/<sha256>.reader` and says so. |

Global vim marks (A–Z) live in `~/Library/Application Support/Reader/global-marks.md`, not in the sidecar. There is no git history of sidecars. Git is only for this source tree.

Lookups are saved automatically (word, dictionary definition, sentence, section, page or CFI). **Undo save** in the lookup popover removes that one lookup. **File → Export All Words…** (⇧⌘E) reads every sidecar in the index and writes one alphabetical Markdown file, or CSV if you choose a `.csv` name. Books the index can no longer find are listed.

## Reading

The center of the window is a `PDFView`. Pinch zoom, ⌘+ / ⌘−, continuous scroll, and single- or two-page layout are PDFKit’s. Reader does not reimplement scrolling.

The sidebar button’s chevron matches Preview:

Hide Sidebar, Thumbnails, Table of Contents, Highlights and Notes, Bookmarks, Contact Sheet, then Continuous Scroll, Single Page, Two Pages.

Highlights and Notes in the sidebar is the Preview-style annotation list. The right-hand inspector (Notes, Words, Highlights, Ask AI) stays as well.

The title bar subtitle is `Page N of M`, and `Page N of M — Edited` while sidecar changes are unsaved. Autosave writes the sidecar and does not rewrite the PDF or EPUB. Rotation and bookmarks are stored in `state.json` and applied in memory, so the book file itself is left alone.

EPUB is a `WKWebView`, not Readium. Readium’s navigator is a large UIKit-centered stack, it does not build on Linux where the core tests run, and it wants to own the view. Reader needs Preview’s chrome (sidebar modes, contact sheet, our inspector), so the app owns the view. `ReaderCore` unzips the EPUB, reads the package and the nav or NCX, extracts text, and round-trips a CFI subset (`epubcfi(/6/<spine-step>!…)` plus character offsets). The quote, prefix, and suffix are what re-anchoring uses if the CFI goes stale. Zoom changes the font size. “Pages” are spine items.

### Marks

With focus in the document, and not in a text field:

- `m`, then a key, sets a mark. Lowercase, digits, and punctuation are per book. `A`–`Z` are global and open that book if it is a different one. Setting a mark again overwrites it.
- `` ` ``, then the key, jumps to it.
- `` ` ` `` jumps to the position before the last jump, and the toolbar Back stack records it too.

A toast says `Mark a set` or `Jumped to a`. The position stored is the PDF page, scroll fraction, zoom, and PDF point, or an EPUB CFI. Local marks are in `marks.md`. The Bookmarks sidebar has a Marks section.

### Keyboard

Preview’s viewing shortcuts win where the design draft overlapped them. ⌘1, ⌘2, and ⌘3 are Continuous Scroll, Single Page, and Two Pages. The inspector tabs are ⌃1–⌃4. Fit Width (⌘8) is extra; Zoom to Fit is ⌘9, as in Preview. Help → Keyboard Shortcuts lists the full set.

## Vault mode

If the book lives inside an Obsidian vault (a parent folder contains `.obsidian`), Reader does not create a `.reader` package. The book folder is the file's parent, for example `books/beginning-of-infinity/`.

- Notes and highlights are appended to `notes/Chapter N.md`. Reader only edits blocks it wrote, wrapped as `<!-- reader:begin id=... -->` … `<!-- reader:end -->`. Hand-written outline text is left byte for byte. Each block ends with `[↗ Open in Reader](reader://open?...)` and an Obsidian block id `^id`.
- Words go to `learner/vocabulary.md` when that file exists, otherwise `words.md`. The heading is `# Vocabulary — <title>`, then `## Chapter N` and `### Word` with Meaning, Book context, and Added. In plain language and Example are omitted when empty. Hand-written entries are shown in the Words tab and are not rewritten.
- Marks and view state live in hidden `.reader-state.json` (notes folder, vocab path, Claude session id, concept-marker toggle).
- Reader watches the book folder and reloads external edits after about a quarter second. Its own writes are ignored. If the same Reader block changed on both sides, both copies are kept and flagged.
- `reader://open?path=&loc=&id=` opens the book and can scroll to the passage. Tools → Reveal in Obsidian opens `obsidian://open`.
- `curriculum/concepts.md` supplies `[[wikilinks]]`, find-terms, and Claim/Trap. Missing concept stubs can be created under `concepts/` and are never overwritten. View → Concept Markers underlines those terms; badge color comes from `learner/mastery.json` and is grey when a concept is absent.
- If `CLAUDE.md` is in the book folder, Ask AI can run Claude Code with that folder as the working directory, `--resume` / `--continue` (not a one-shot ephemeral session), and write access limited to `learner/`, `learning/`, and `reviews/`. Learn, Review, and Wrap send `/learn`, `/review`, and `/wrap`. Reader appends a `reader_passage_question` line to `learning/events.jsonl` without the passage text.

Books outside a vault keep the `.reader` sidecar.

## Layout

```
project.yml                  XcodeGen project
App/Reader                   SwiftUI + AppKit shell, PDFView, WKWebView, menus
Packages/ReaderCore          Sidecars, anchors, EPUB, words, prompts, CLI argv
```

## Known gaps

Verified here: `Packages/ReaderCore` unit tests on Linux. Vault tests cover block preservation, vocabulary order, concept parsing, mastery, tutor events, and sync conflicts. That covers SHA-256, PDF trailer ids, ZIP store and deflate, EPUB package/nav/text, CFI parse and build, Markdown round-trip for notes, words, highlights, and marks, sidecar create / rename / move offer / unwritable fallback / stable-id refresh / re-anchor, word undo and export, prompt assembly including the long-book fallback, OpenAI and Anthropic request shape and SSE parsing, and the exact `claude` / `codex` argument lists.

Not verified here, because this environment has no Xcode and no Mac:

- The Xcode project has not been generated or built. `xcodegen generate` then build the Reader scheme on a Mac.
- Nothing about the window was run: PDFView smoothness, pinch zoom, contact sheet, note overlay, lookup popover, keychain, or Dictionary Services.
- `claude` and `codex` were not executed. Flags come from the public CLI docs as of November 2026 (`--tools` vs `--allowedTools`, `codex exec`, `--ask-for-approval never`, `--skip-git-repo-check`). A future CLI can rename a flag; the panel shows the tool’s own error text.
- EPUB rendering quality is below Readium: spine-level “pages”, CSS columns for two-page mode, a CFI subset, and looked-up words are not yet painted with a dotted underline in the web view.
- PDF notes are cards anchored under the passage. PDFKit does not reflow text, so the note does not push the paragraph down. Space scrolls the page, as in Preview; it expands a note when that note’s margin control is focused.
- Highlights, underlines, bookmarks, and rotation are not written into the PDF. Other apps will not see them. “Edited” means the sidecar has unsaved changes.
- Flip Horizontal and Flip Vertical are not implemented.
- Preview’s image viewing, Customize Toolbar, and a polished slideshow are not in this version. Slideshow turns pages every three seconds until Escape.
- File → Open Recent is not a separate menu. The welcome window lists recent books.
- API answers are parsed from the full HTTP body, so they show up at once. CLI output is streamed. Suggested notes, quizzes, and “ask your notes” from the design’s extra-ideas list are not built; the suggested-notes setting stays off.
- Very large ZIP64 EPUBs are not read.
- The app icon is a simple generated image.
