# Reader for iPhone and Android

Expo spike for highlighting. The Mac app and `Packages/ReaderCore` are unchanged. Shared schemas will live in `spec/` later; until those files exist, the phone keeps its own copy of the record and anchor types.

## Contract

`src/contract/` is the temporary TypeScript contract. A header in `types.ts` says these types will be generated from `spec/`.

- A book is a `sha256:` fingerprint of the file bytes, plus a PDF id or an EPUB id.
- Word ids are `w_` plus Swift `trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`, per code point and without Unicode normalization.
- A highlight and its note are separate records. The note's `highlightId` points at the highlight. Sidecar comments still store that link on the highlight under the key `note`.
- The anchor of record is quote + prefix + suffix. Page, CFI, and rects are hints. Reanchor keeps at most 80 characters of context.

Anchor vectors are JSON in `src/contract/fixtures/` so they can move to `spec/` later.

## Run

```bash
cd apps/mobile
npm install
npm test
npm run typecheck
npm run web
```

Tap the first word of a passage, then the last, then a color. The swatches are the shared highlight palette at the token opacity on the page. "Move chapter 4 and re-anchor" shifts that sentence and finds it again from the quote, prefix, and suffix.
