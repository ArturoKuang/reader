import { Directory, File, Paths } from "expo-file-system";

function booksRoot(): Directory {
  const root = new Directory(Paths.cache, "reader-books");
  if (!root.exists) root.create({ intermediates: true });
  return root;
}

export function cachedBookFile(sha256: string, format: "pdf" | "epub"): File {
  const ext = format === "epub" ? "epub" : "pdf";
  return new File(booksRoot(), `${sha256}.${ext}`);
}

export function isBookCached(sha256: string, format: "pdf" | "epub"): boolean {
  return cachedBookFile(sha256, format).exists;
}

export async function readCachedBookBase64(sha256: string, format: "pdf" | "epub"): Promise<string | null> {
  const file = cachedBookFile(sha256, format);
  if (!file.exists) return null;
  return file.base64();
}

export async function writeCachedBook(sha256: string, format: "pdf" | "epub", bytes: Uint8Array): Promise<File> {
  const file = cachedBookFile(sha256, format);
  if (file.exists) file.delete();
  file.create();
  await file.write(bytes);
  return file;
}

export function cachedShaSet(books: readonly { sha256: string; format: "pdf" | "epub" }[]): Set<string> {
  const cached = new Set<string>();
  for (const book of books) {
    if (isBookCached(book.sha256, book.format)) cached.add(book.sha256);
  }
  return cached;
}
