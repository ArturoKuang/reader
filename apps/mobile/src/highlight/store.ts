import type { HighlightRecord, NoteRecord, PassageAnchor } from "../contract/types";
import { isHighlightColor } from "../contract/types";
import { locate, type AnchorHit, type TextSlice } from "./locate";

export interface AnchorDraft {
  quote: string;
  prefix: string;
  suffix: string;
  page?: number;
  cfi?: string;
  section?: string;
  rects?: number[][];
}

/**
 * AnnotationEdit.addHighlight. The same quote on the same page and CFI
 * returns the existing highlight instead of inserting another.
 */
export function addHighlight(
  highlights: readonly HighlightRecord[],
  draft: AnchorDraft,
  color: number,
  id: string,
): { highlights: HighlightRecord[]; entry: HighlightRecord | null } {
  if (!isHighlightColor(color) || draft.quote.length === 0) {
    return { highlights: [...highlights], entry: null };
  }
  const existing = highlights.find(
    (highlight) =>
      highlight.quote === draft.quote && highlight.page === draft.page && highlight.cfi === draft.cfi,
  );
  if (existing) return { highlights: [...highlights], entry: existing };
  const entry: HighlightRecord = {
    id,
    color,
    page: draft.page,
    cfi: draft.cfi,
    quote: draft.quote,
    prefix: draft.prefix,
    suffix: draft.suffix,
    section: draft.section,
    rects: draft.rects ?? [],
    extras: {},
  };
  return { highlights: [...highlights, entry], entry };
}

function noteFromHighlight(highlight: HighlightRecord, body: string, now: string): NoteRecord {
  return {
    id: highlight.id,
    page: highlight.page,
    cfi: highlight.cfi,
    quote: highlight.quote,
    prefix: highlight.prefix,
    suffix: highlight.suffix,
    section: highlight.section,
    created: now,
    ai: false,
    scope: "passage",
    body,
    extras: {},
  };
}

/**
 * Creates or updates a note as its own record with the highlight's id.
 * An empty body removes that note. The highlight record is left unchanged.
 */
export function saveNote(
  highlights: readonly HighlightRecord[],
  notes: readonly NoteRecord[],
  highlightId: string,
  body: string,
  now: string,
): { highlights: HighlightRecord[]; notes: NoteRecord[] } | null {
  const highlight = highlights.find((item) => item.id === highlightId);
  if (!highlight) return null;
  const trimmed = body.trim();
  if (trimmed.length === 0) {
    return {
      highlights: [...highlights],
      notes: notes.filter((note) => note.id !== highlight.id),
    };
  }
  const existing = notes.some((note) => note.id === highlight.id);
  return {
    highlights: [...highlights],
    notes: existing
      ? notes.map((note) => (note.id === highlight.id ? { ...note, body: trimmed, updated: now } : note))
      : [...notes, noteFromHighlight(highlight, trimmed, now)],
  };
}

export function removeHighlight(
  highlights: readonly HighlightRecord[],
  notes: readonly NoteRecord[],
  highlightId: string,
): { highlights: HighlightRecord[]; notes: NoteRecord[] } {
  return {
    highlights: highlights.filter((item) => item.id !== highlightId),
    notes: notes.filter((note) => note.id !== highlightId),
  };
}

function applyHit<T extends PassageAnchor>(record: T, hit: AnchorHit | null): { record: T; found: boolean } {
  if (!hit) return { record, found: false };
  return {
    found: true,
    record: {
      ...record,
      page: hit.page ?? record.page,
      section: hit.section ?? record.section,
      prefix: hit.prefix,
      suffix: hit.suffix,
      cfi: hit.cfi ?? record.cfi,
    },
  };
}

/** Reanchorer.apply for the highlight and note records this spike stores. */
export function reanchorRecords(
  highlights: readonly HighlightRecord[],
  notes: readonly NoteRecord[],
  corpus: readonly TextSlice[],
): { highlights: HighlightRecord[]; notes: NoteRecord[]; unresolvedIDs: string[] } {
  const unresolvedIDs: string[] = [];
  const nextNotes = notes.map((note) => {
    const applied = applyHit(note, locate(note.quote, note.prefix, note.suffix, corpus));
    if (!applied.found) unresolvedIDs.push(note.id);
    return applied.record;
  });
  const nextHighlights = highlights.map((highlight) => {
    const applied = applyHit(
      highlight,
      locate(highlight.quote, highlight.prefix, highlight.suffix, corpus),
    );
    if (!applied.found) unresolvedIDs.push(highlight.id);
    return applied.record;
  });
  return { highlights: nextHighlights, notes: nextNotes, unresolvedIDs };
}

function syncNoteAnchor(note: NoteRecord, highlight: HighlightRecord): NoteRecord {
  return {
    ...note,
    page: highlight.page,
    cfi: highlight.cfi,
    section: highlight.section,
    prefix: highlight.prefix,
    suffix: highlight.suffix,
    quote: highlight.quote,
  };
}

/**
 * True when the primary hint still finds the quote: a PDF page that
 * contains it, or an EPUB CFI whose spine step matches a quote hit.
 */
export function primaryHintResolves(
  highlight: Pick<HighlightRecord, "quote" | "prefix" | "suffix" | "page" | "cfi">,
  corpus: readonly TextSlice[],
): boolean {
  if (highlight.page != null) {
    const slice = corpus.find((item) => item.page === highlight.page);
    if (!slice) return false;
    return locate(highlight.quote, highlight.prefix, highlight.suffix, [slice]) !== null;
  }
  if (highlight.cfi) {
    const hit = locate(highlight.quote, highlight.prefix, highlight.suffix, corpus);
    if (!hit) return false;
    if (hit.cfi && !cfiSameSpine(highlight.cfi, hit.cfi)) return false;
    return true;
  }
  return false;
}

function cfiSameSpine(stored: string, computed: string): boolean {
  const stepOf = (cfi: string): number | null => {
    const match = /epubcfi\(\/6\/(\d+)/.exec(cfi);
    return match ? Number(match[1]) : null;
  };
  const storedStep = stepOf(stored);
  const computedStep = stepOf(computed);
  if (storedStep == null || computedStep == null) return stored === computed;
  return storedStep === computedStep;
}

export interface LocatedAnchor {
  id: string;
  found: boolean;
  page?: number;
  cfi?: string;
  section?: string;
  prefix: string;
  suffix: string;
  rects: number[][];
}

/**
 * Persist a viewer locate result onto the existing highlight and, if
 * present, its linked note (`note.id === highlight.id`). Never creates
 * a new highlight or note.
 */
export function persistReanchoredHighlight(
  highlights: readonly HighlightRecord[],
  notes: readonly NoteRecord[],
  located: LocatedAnchor,
): { highlights: HighlightRecord[]; notes: NoteRecord[] } | null {
  const current = highlights.find((highlight) => highlight.id === located.id);
  if (!current) return null;
  if (!located.found) return { highlights: [...highlights], notes: [...notes] };
  const updated: HighlightRecord = {
    ...current,
    page: located.page ?? current.page,
    cfi: located.cfi ?? current.cfi,
    section: located.section ?? current.section,
    prefix: located.prefix,
    suffix: located.suffix,
    rects: located.rects.length > 0 ? located.rects : current.rects,
  };
  return {
    highlights: highlights.map((highlight) => (highlight.id === updated.id ? updated : highlight)),
    notes: notes.map((note) => (note.id === updated.id ? syncNoteAnchor(note, updated) : note)),
  };
}

/**
 * On book open, keep highlights whose primary hint still resolves.
 * Otherwise re-anchor from quote + prefix + suffix, update the existing
 * record (and its linked note) in place, and leave the id unchanged.
 */
export function autoReanchorOnOpen(
  highlights: readonly HighlightRecord[],
  notes: readonly NoteRecord[],
  corpus: readonly TextSlice[],
): { highlights: HighlightRecord[]; notes: NoteRecord[]; reanchoredIds: string[] } {
  const reanchoredIds: string[] = [];
  const nextHighlights = highlights.map((highlight) => {
    if (primaryHintResolves(highlight, corpus)) return highlight;
    const applied = applyHit(
      highlight,
      locate(highlight.quote, highlight.prefix, highlight.suffix, corpus),
    );
    if (!applied.found) return highlight;
    reanchoredIds.push(highlight.id);
    return applied.record;
  });
  const byId = new Map(nextHighlights.map((highlight) => [highlight.id, highlight]));
  const nextNotes = notes.map((note) => {
    const highlight = byId.get(note.id);
    return highlight ? syncNoteAnchor(note, highlight) : note;
  });
  return { highlights: nextHighlights, notes: nextNotes, reanchoredIds };
}
