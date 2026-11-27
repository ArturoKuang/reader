import type { BookListItem } from "./wire";
import { SyncApiError, type SyncTransport } from "./transport";

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", copy);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/**
 * Current file when it has a blob. Otherwise the last listed file that has one
 * (the server appends files, so the last is the newest).
 */
export function chooseBlobFile(book: BookListItem): { sha256: string; size: number } | null {
  if (book.hasBlob) return { sha256: book.sha256, size: book.size };
  const available = book.files.filter((file) => file.hasBlob);
  const newest = available[available.length - 1];
  return newest ? { sha256: newest.sha256, size: newest.size } : null;
}

const CHUNK = 64 * 1024;

/** Download a book file in ranges and reject it unless the bytes hash to `sha256`. */
export async function downloadBookBlob(transport: SyncTransport, book: BookListItem): Promise<Uint8Array> {
  const chosen = chooseBlobFile(book);
  if (!chosen) throw new SyncApiError(404, "not_found", "no blob for this book");
  const chunks: Uint8Array[] = [];
  let offset = 0;
  while (offset < chosen.size) {
    const end = Math.min(chosen.size, offset + CHUNK) - 1;
    const part = await transport.blob(chosen.sha256, { start: offset, end });
    chunks.push(part.body);
    if (part.status === 200) break;
    if (part.body.length === 0) break;
    offset += part.body.length;
  }
  const bytes = concat(chunks);
  const digest = await sha256Hex(bytes);
  if (digest !== chosen.sha256) {
    throw new SyncApiError(422, "hash_mismatch", `blob hashed to ${digest}, expected ${chosen.sha256}`);
  }
  return bytes;
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
