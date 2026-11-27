import { progressRatio, type BookProgress } from "./progress";
import type { BookListItem } from "../sync/wire";

export type LibrarySource = "sample" | "synced" | "both";

export interface SampleBookSpec {
  title: string;
  format: "pdf" | "epub";
  fingerprint: string;
  sha256: string;
  size: number;
  docId?: string;
  filename: string;
  testID: string;
}

export interface LibraryBook {
  id: string;
  title: string;
  format: "pdf" | "epub";
  fingerprint: string;
  sha256: string;
  size: number;
  docId?: string;
  filename: string;
  source: LibrarySource;
  cached: boolean;
  waitingForSpace: boolean;
  highlightCount: number;
  noteCount: number;
  progress: number | null;
  page?: number;
  pageCount?: number;
  lastReadAt: number;
  testID?: string;
}

export interface LibraryCounts {
  highlights: number;
  notes: number;
}

export interface BuildLibraryInput {
  samples: readonly SampleBookSpec[];
  remote: readonly BookListItem[];
  pausedBookIds: readonly string[];
  counts: Readonly<Record<string, LibraryCounts>>;
  progress: Readonly<Record<string, BookProgress | null | undefined>>;
  cachedSha: ReadonlySet<string>;
}

function asFormat(value: string): "pdf" | "epub" {
  return value.toLowerCase() === "epub" ? "epub" : "pdf";
}

function shaOf(fingerprintOrSha: string): string {
  return fingerprintOrSha.startsWith("sha256:") ? fingerprintOrSha.slice("sha256:".length) : fingerprintOrSha;
}

function bookIdOf(sha256: string): string {
  return sha256.startsWith("sha256:") ? sha256 : `sha256:${sha256}`;
}

function countsFor(map: BuildLibraryInput["counts"], bookId: string): LibraryCounts {
  return map[bookId] ?? map[shaOf(bookId)] ?? { highlights: 0, notes: 0 };
}

function progressFor(map: BuildLibraryInput["progress"], bookId: string): BookProgress | null {
  return map[bookId] ?? map[shaOf(bookId)] ?? null;
}

function fromSample(
  sample: SampleBookSpec,
  input: BuildLibraryInput,
  remote?: BookListItem,
): LibraryBook {
  const id = sample.fingerprint;
  const counts = countsFor(input.counts, id);
  const progress = progressFor(input.progress, id);
  const paused = input.pausedBookIds.includes(id) || input.pausedBookIds.includes(sample.sha256);
  return {
    id,
    title: remote?.title || sample.title,
    format: sample.format,
    fingerprint: sample.fingerprint,
    sha256: sample.sha256,
    size: remote?.size || sample.size,
    docId: remote?.docId ?? sample.docId,
    filename: remote?.filename || sample.filename,
    source: remote ? "both" : "sample",
    cached: true,
    waitingForSpace: paused,
    highlightCount: counts.highlights,
    noteCount: counts.notes,
    progress: progressRatio(progress),
    page: progress?.page,
    pageCount: progress?.pageCount,
    lastReadAt: progress?.updatedAt ?? 0,
    testID: sample.testID,
  };
}

function fromRemote(item: BookListItem, input: BuildLibraryInput): LibraryBook {
  const id = item.bookId;
  const sha = shaOf(item.sha256 || id);
  const counts = countsFor(input.counts, id);
  const progress = progressFor(input.progress, id);
  const paused = input.pausedBookIds.includes(id) || input.pausedBookIds.includes(bookIdOf(sha));
  return {
    id,
    title: item.title || item.filename || "Untitled",
    format: asFormat(item.format),
    fingerprint: bookIdOf(sha),
    sha256: sha,
    size: item.size,
    docId: item.docId,
    filename: item.filename,
    source: "synced",
    cached: input.cachedSha.has(sha),
    waitingForSpace: paused,
    highlightCount: counts.highlights,
    noteCount: counts.notes,
    progress: progressRatio(progress),
    page: progress?.page,
    pageCount: progress?.pageCount,
    lastReadAt: progress?.updatedAt ?? 0,
  };
}

/**
 * Sample books always appear (and keep their Maestro testIDs). Synced books
 * that share a sample SHA are merged, not duplicated. Most recently read first.
 */
export function buildLibrary(input: BuildLibraryInput): LibraryBook[] {
  const used = new Set<string>();
  const books: LibraryBook[] = [];
  for (const sample of input.samples) {
    const remote = input.remote.find((item) => {
      const sha = shaOf(item.sha256 || item.bookId);
      return sha === sample.sha256 || item.bookId === sample.fingerprint;
    });
    if (remote) {
      used.add(remote.bookId);
      used.add(shaOf(remote.sha256 || remote.bookId));
    }
    books.push(fromSample(sample, input, remote));
  }
  for (const item of input.remote) {
    const sha = shaOf(item.sha256 || item.bookId);
    if (used.has(item.bookId) || used.has(sha)) continue;
    books.push(fromRemote(item, input));
  }
  return books.sort((left, right) => {
    if (right.lastReadAt !== left.lastReadAt) return right.lastReadAt - left.lastReadAt;
    const leftSample = left.source === "synced" ? 1 : 0;
    const rightSample = right.source === "synced" ? 1 : 0;
    if (leftSample !== rightSample) return leftSample - rightSample;
    return left.title.localeCompare(right.title);
  });
}

export function librarySubtitle(book: LibraryBook): string {
  const format = book.format.toUpperCase();
  if (book.waitingForSpace) return `${format} · Waiting for space`;
  const counts: string[] = [];
  if (book.progress !== null) counts.push(`${Math.round(book.progress * 100)}%`);
  else if (book.page) counts.push(`p. ${book.page}`);
  counts.push(`${book.highlightCount} highlight${book.highlightCount === 1 ? "" : "s"}`);
  if (book.noteCount > 0) counts.push(`${book.noteCount} note${book.noteCount === 1 ? "" : "s"}`);
  counts.push(format);
  if (book.source !== "sample" && !book.cached) {
    const size = book.size > 0 ? ` · ${formatSize(book.size)}` : "";
    return `On Mac mini · ${format}${size} · Tap to download`;
  }
  return counts.join(" · ");
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  const mb = bytes / (1024 * 1024);
  return `${mb >= 10 ? Math.round(mb) : mb.toFixed(1)} MB`;
}
