import type { HighlightRecord, NoteRecord } from "../contract/types";

export interface BookShelf {
  lastColor: number;
  highlights: HighlightRecord[];
  notes: NoteRecord[];
}

export function emptyShelf(): BookShelf {
  return { lastColor: 1, highlights: [], notes: [] };
}

export function parseShelf(raw: string | null): BookShelf {
  if (!raw) return emptyShelf();
  try {
    const value = JSON.parse(raw) as Partial<BookShelf>;
    const lastColor = value.lastColor;
    return {
      lastColor: typeof lastColor === "number" && lastColor >= 1 && lastColor <= 6 ? lastColor : 1,
      highlights: Array.isArray(value.highlights) ? value.highlights : [],
      notes: Array.isArray(value.notes) ? value.notes : [],
    };
  } catch {
    return emptyShelf();
  }
}

export function serializeShelf(shelf: BookShelf): string {
  return JSON.stringify(shelf);
}

export function shelfKey(fingerprint: string): string {
  return `reader.book.${fingerprint}`;
}
