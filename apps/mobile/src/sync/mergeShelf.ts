import type { BookShelf } from "../reader/shelf";
import { highlightFromPayload, noteFromPayload } from "./payload";
import type { LocalRecord } from "./storage";

/**
 * Merge pulled highlight and note records into a book shelf.
 * Dirty (un-acked) engine records do not overwrite a local copy.
 * Deleted remote records are removed. Local-only records stay.
 */
export function mergeSyncRecords(shelf: BookShelf, records: readonly LocalRecord[]): BookShelf {
  const highlights = new Map(shelf.highlights.map((highlight) => [highlight.id, highlight]));
  const notes = new Map(shelf.notes.map((note) => [note.id, note]));
  for (const record of records) {
    if (record.kind === "highlight") {
      if (record.deleted) {
        highlights.delete(record.id);
        continue;
      }
      const converted = highlightFromPayload(record.id, record.payload);
      if (!converted) continue;
      const local = highlights.get(record.id);
      if (!local || !record.dirty) highlights.set(record.id, converted);
    } else if (record.kind === "note") {
      if (record.deleted) {
        notes.delete(record.id);
        continue;
      }
      const converted = noteFromPayload(record.id, record.payload);
      if (!converted) continue;
      const local = notes.get(record.id);
      if (!local || !record.dirty) notes.set(record.id, converted);
    }
  }
  return {
    lastColor: shelf.lastColor,
    highlights: [...highlights.values()],
    notes: [...notes.values()],
  };
}
