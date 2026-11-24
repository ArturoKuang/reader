export {
  HIGHLIGHT_OPACITY,
  HIGHLIGHT_PALETTE,
  isHighlightColor,
} from "./types";
export type {
  BookIdentity,
  HighlightRecord,
  IdentityMatch,
  JsonValue,
  LookupRecord,
  NoteRecord,
  PassageAnchor,
  WordRecord,
} from "./types";
export { isSha256Fingerprint, matchBookIdentity, readEpubIdentifier, scanPdfId } from "./book";
export {
  compactJson,
  highlightSidecarObject,
  lookupSidecarObject,
  noteSidecarObject,
  readerComment,
} from "./sidecar";
export { codePointsOf, normalizeWord, wordId } from "./wordId";
