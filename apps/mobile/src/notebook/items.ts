import type { HighlightRecord, NoteRecord, WordRecord } from "../contract/types";
import type { OpenConflict } from "../sync/wire";

export type NotebookTab = "highlights" | "notes" | "words";

export interface NotebookItem {
  id: string;
  tab: NotebookTab;
  bookId: string;
  bookTitle: string;
  color?: number;
  quote: string;
  note?: string;
  locationLabel: string;
  conflict: OpenConflict | null;
}

export interface NotebookSource {
  bookId: string;
  bookTitle: string;
  highlights: readonly HighlightRecord[];
  notes: readonly NoteRecord[];
  words: readonly WordRecord[];
  conflicts: readonly OpenConflict[];
}

export function locationLabel(input: { page?: number; section?: string }): string {
  if (typeof input.page === "number" && input.page > 0) return `p. ${input.page}`;
  if (input.section && input.section.trim()) return input.section;
  return "";
}

function conflictFor(
  conflicts: readonly OpenConflict[],
  bookId: string,
  kind: OpenConflict["kind"],
  id: string,
): OpenConflict | null {
  return conflicts.find((conflict) => conflict.bookId === bookId && conflict.kind === kind && conflict.id === id) ?? null;
}

/**
 * Per-book notebook rows. Highlights include an attached note when the
 * note shares the highlight id. Notes tab lists only those with a body.
 */
export function buildNotebookItems(source: NotebookSource): NotebookItem[] {
  const notes = new Map(source.notes.map((note) => [note.id, note]));
  const items: NotebookItem[] = [];
  for (const highlight of source.highlights) {
    const note = notes.get(highlight.id);
    items.push({
      id: highlight.id,
      tab: "highlights",
      bookId: source.bookId,
      bookTitle: source.bookTitle,
      color: highlight.color,
      quote: highlight.quote,
      note: note?.body.trim() || undefined,
      locationLabel: locationLabel(highlight),
      conflict:
        conflictFor(source.conflicts, source.bookId, "highlight", highlight.id) ??
        conflictFor(source.conflicts, source.bookId, "note", highlight.id),
    });
  }
  for (const note of source.notes) {
    if (!note.body.trim()) continue;
    items.push({
      id: note.id,
      tab: "notes",
      bookId: source.bookId,
      bookTitle: source.bookTitle,
      color: source.highlights.find((highlight) => highlight.id === note.id)?.color,
      quote: note.quote,
      note: note.body,
      locationLabel: locationLabel(note),
      conflict: conflictFor(source.conflicts, source.bookId, "note", note.id),
    });
  }
  for (const word of source.words) {
    items.push({
      id: word.id,
      tab: "words",
      bookId: source.bookId,
      bookTitle: source.bookTitle,
      quote: word.word,
      note: word.definition,
      locationLabel: "",
      conflict: conflictFor(source.conflicts, source.bookId, "word", word.id),
    });
  }
  return items;
}

export function filterNotebook(items: readonly NotebookItem[], tab: NotebookTab): NotebookItem[] {
  return items.filter((item) => item.tab === tab);
}

export function notebookCounts(items: readonly NotebookItem[]): Record<NotebookTab, number> {
  return {
    highlights: filterNotebook(items, "highlights").length,
    notes: filterNotebook(items, "notes").length,
    words: filterNotebook(items, "words").length,
  };
}
