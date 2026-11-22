/**
 * Hand-written record and anchor types for the phone spike.
 * These will be generated from spec/ once that folder exists.
 *
 * Derived from Packages/ReaderCore/Sources/ReaderCore/Models.swift and
 * checked against the Mac record-to-markdown mapping. Wire names follow
 * that mapping (pdfId, epubId, noteId). Sidecar comment keys that differ
 * are applied in `sidecar.ts`, not by renaming the fields here.
 *
 * A book is `fingerprint` (`sha256:` + lowercase hex of the file bytes)
 * plus its PDF id or EPUB id. A highlight and its note are separate
 * records. The note points at its highlight with `highlightId`. The
 * sidecar still stores the inverse comment key `note` on the highlight
 * (`noteId` here).
 */

export type JsonValue =
  | null
  | boolean
  | number
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

/**
 * HighlightPalette.hex. Files store the 1-based index, so order is the
 * contract. The phone paints these at HighlightAppearance.opacity (0.38).
 */
export const HIGHLIGHT_PALETTE = [
  "F2C94C",
  "6FCF97",
  "56CCF2",
  "F28FB1",
  "BB6BD9",
  "F2994A",
] as const;

export const HIGHLIGHT_OPACITY = 0.38;

export function isHighlightColor(color: number): boolean {
  return Number.isInteger(color) && color >= 1 && color <= HIGHLIGHT_PALETTE.length;
}

/** Quote + prefix + suffix are the anchor of record. Page, CFI, and rects are hints. */
export interface PassageAnchor {
  quote: string;
  /** At most 80 characters after reanchor. Empty string when unknown. */
  prefix: string;
  /** At most 80 characters after reanchor. Empty string when unknown. */
  suffix: string;
  /** 1-based PDF page. Hint. */
  page?: number;
  /** Raw EPUB CFI, preserved even when this client does not interpret it. Hint. */
  cfi?: string;
  section?: string;
}

/**
 * Identity of one book file. Equal fingerprints are the same bytes.
 * A non-empty pdfId or epubId still matches after a small edit that
 * changes the digest (SidecarStore identity match).
 */
export interface BookIdentity {
  /** `sha256:` + 64 lowercase hex digits. Never the bare digest. */
  fingerprint: string;
  /** PDF trailer `/ID`, lowercase hex digits only. Absent for EPUB and when missing. */
  pdfId?: string;
  /** First `dc:identifier`, trimmed. Absent for PDF and when missing. */
  epubId?: string;
}

export interface HighlightRecord extends PassageAnchor {
  /** Client-made `h_` + lowercase UUID without hyphens. */
  id: string;
  /** 1...6. */
  color: number;
  /**
   * PDF user space `[minX, minY, maxX, maxY]`, origin bottom-left.
   * Empty for EPUB and for this text spike.
   */
  rects: number[][];
  /**
   * Points at a separate NoteRecord. The sidecar comment key is `note`,
   * not `noteId`. Absent when the highlight has no note.
   */
  noteId?: string;
  /** Unknown comment keys, passed through untouched. */
  extras: { [key: string]: JsonValue };
}

export interface NoteRecord extends PassageAnchor {
  /** Client-made `n_` + lowercase UUID without hyphens. */
  id: string;
  /**
   * The highlight this note belongs to. Absent for a note that has no
   * highlight. The note does not embed the highlight's color or rects.
   */
  highlightId?: string;
  /** ISO-8601 when the app set it. */
  created?: string;
  /** ISO-8601 when the app set it. */
  updated?: string;
  /** Default false. The sidecar writes `ai` only when true. */
  ai: boolean;
  provider?: string;
  /** Default `passage`. The sidecar writes `scope` only when it differs. */
  scope: string;
  body: string;
  extras: { [key: string]: JsonValue };
}

export interface LookupRecord extends PassageAnchor {
  /** Client-made `l_` + lowercase UUID without hyphens. Sidecar key is `lookup`. */
  id: string;
  sentence: string;
  date: string;
  extras: { [key: string]: JsonValue };
}

export interface WordRecord {
  /**
   * `w_` + the normalized word. Deterministic across clients, not a UUID.
   * See `wordId`.
   */
  id: string;
  /** Normalized spelling, which is also the `##` heading. */
  word: string;
  definition: string;
  explanation?: string;
  explanationProvider?: string;
  pronunciation?: string;
  partOfSpeech?: string;
  learned: boolean;
  lookups: LookupRecord[];
  extras: { [key: string]: JsonValue };
}

export type IdentityMatch = "exact" | "stableID" | "different";
