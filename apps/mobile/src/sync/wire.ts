/**
 * Wire types for Reader sync, spec rev 3.
 *
 * This file is the stand-in for types that will be generated from
 * `spec/schemas` with quicktype. Keep every request and response shape
 * here and nowhere else. Payload fields that already exist on the phone
 * reuse `PassageAnchor` and `JsonValue` from `src/contract`.
 */

import type { JsonValue, PassageAnchor } from "../contract/types";

export const PROTOCOL_VERSION = 1 as const;

export const LIMITS = {
  maxChangesPerBatch: 500,
  maxBatchBytes: 8 * 1024 * 1024,
  maxPayloadBytes: 1024 * 1024,
  maxPullLimit: 1000,
  maxIdBytes: 512,
} as const;

export type RecordKind = "highlight" | "note" | "word" | "lookup" | "position" | "book";

/** Kinds a phone may push. Book records are server-written. */
export type ClientKind = Exclude<RecordKind, "book">;

export type DeviceKind = "mac" | "phone";

/**
 * HTTP error codes from spec rev 3, plus the per-change codes the push
 * rules name (`use_register`, `unknown_book`, `bad_base`, `not_owner`).
 */
export type ErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "bad_request"
  | "change_id_reused"
  | "hash_mismatch"
  | "range_not_satisfiable"
  | "too_large"
  | "already_resolved"
  | "stale_base"
  | "upload_offset_mismatch"
  | "server_busy"
  | "use_register"
  | "unknown_book"
  | "bad_base"
  | "not_owner"
  | "disk_full"
  | "quota_exceeded";

export interface ApiErrorBody {
  error: { code: ErrorCode | string; message: string };
}

export interface ExtrasCarrier {
  /** Clients copy this through untouched, including nested values. */
  extras: { [key: string]: JsonValue };
}

export interface HighlightPayload extends PassageAnchor, ExtrasCarrier {
  /** 1 through 6. */
  color: number;
  rects?: number[][];
}

export interface NotePayload extends PassageAnchor, ExtrasCarrier {
  created?: string;
  updated?: string;
  ai: boolean;
  provider?: string;
  scope: string;
  body: string;
}

/** A word record does not embed lookups. Lookups are their own kind. */
export interface WordPayload extends ExtrasCarrier {
  word: string;
  definition: string;
  explanation?: string;
  explanationProvider?: string;
  pronunciation?: string;
  partOfSpeech?: string;
  learned: boolean;
}

export interface LookupPayload extends PassageAnchor, ExtrasCarrier {
  wordId: string;
  sentence: string;
  date: string;
}

export interface PdfPoint {
  x: number;
  y: number;
}

export interface PdfLocator {
  format: "pdf";
  /** 1-based. */
  page: number;
  point?: PdfPoint;
}

export interface EpubLocator {
  format: "epub";
  /** Full CFI. The phone does not trim this. */
  cfi: string;
  /** 0 through 1, when the reader has one. */
  progression?: number;
}

export type Locator = PdfLocator | EpubLocator;

export interface PositionPayload extends ExtrasCarrier {
  bookId: string;
  deviceId: string;
  locator: Locator;
}

export interface BookFileWire {
  sha256: string;
  size: number;
  addedAt: string;
}

export interface BookPayload extends ExtrasCarrier {
  title: string;
  filename: string;
  format: string;
  docId?: string;
  files: BookFileWire[];
  currentSha256: string;
}

/** JSON object sent as a change payload. Every payload includes `extras`. */
export type JsonObject = { [key: string]: JsonValue };

export interface ConflictSide {
  changeId: string;
  deviceId: string;
  version: number | null;
  deleted: boolean;
  payload: JsonObject;
  clientTime: string;
}

export interface ConflictBase {
  deleted: boolean;
  payload: JsonObject;
}

export interface OpenConflict {
  conflictId: string;
  bookId: string;
  kind: RecordKind;
  id: string;
  baseVersion: number;
  base: ConflictBase | null;
  sides: ConflictSide[];
  openedSeq: number;
}

/**
 * Feed envelope. `seq` and `conflict` are feed-only.
 * `baseVersion` is the base of the change that produced `version`.
 */
export interface Envelope {
  bookId: string;
  kind: RecordKind;
  id: string;
  version: number;
  baseVersion: number;
  deleted: boolean;
  deviceId: string;
  changeId: string;
  clientTime: string;
  seq: number;
  conflict?: OpenConflict;
  payload: JsonObject;
}

export interface ChangeInput {
  changeId: string;
  bookId: string;
  kind: ClientKind;
  id: string;
  /** 0 creates. Otherwise the caller's last acknowledged server version. */
  baseVersion: number;
  deleted: boolean;
  /** Informational. The server stores it and does not order by it. */
  clientTime: string;
  payload: JsonObject;
}

export interface PushRequest {
  batchId: string;
  changes: ChangeInput[];
}

export type ChangeStatus = "applied" | "noop" | "conflict" | "rejected";

export interface ChangeError {
  code: string;
  message: string;
}

export interface ChangeResult {
  changeId: string;
  status: ChangeStatus;
  version?: number;
  seq?: number;
  conflictId?: string;
  error?: ChangeError;
}

export interface PushResponse {
  batchId: string;
  seq: number;
  results: ChangeResult[];
}

export interface PullResponse {
  changes: Envelope[];
  cursor: number;
  hasMore: boolean;
  serverId: string;
}

export interface HealthResponse {
  ok: boolean;
  serverId: string;
  serverVersion: string;
  protocol: typeof PROTOCOL_VERSION;
  seq: number;
}

export interface DeviceInfo {
  deviceId: string;
  name: string;
  platform: string;
  kind: DeviceKind;
}

export interface DevicesResponse {
  devices: DeviceInfo[];
}

export interface BookListFile {
  sha256: string;
  size: number;
  hasBlob: boolean;
}

export interface BookListItem {
  bookId: string;
  title: string;
  filename: string;
  format: string;
  docId?: string;
  /** Current file, bare 64 hex digits. */
  sha256: string;
  size: number;
  hasBlob: boolean;
  files: BookListFile[];
  version: number;
  seq: number;
}

export interface BooksResponse {
  books: BookListItem[];
}

export interface RegisterBookRequest {
  /** Bare 64 lowercase hex digits. */
  sha256: string;
  size: number;
  format: string;
  docId?: string;
  title: string;
  filename: string;
}

export interface RegisterBookResponse {
  status: "existing" | "attached" | "created";
  bookId: string;
  book: BookListItem;
}

export interface RedeemRequest {
  token: string;
  deviceId: string;
  name: string;
  platform: string;
  appVersion: string;
}

export interface RedeemResponse {
  deviceId: string;
  credential: string;
  serverId: string;
  kind: DeviceKind;
}

export interface ConflictsResponse {
  conflicts: OpenConflict[];
}

export interface PairingParts {
  v: "2";
  /** Sync base URL, with no trailing slash. Paths are joined under it. */
  url: string;
  token: string;
  serverId: string;
}

export const PUSH_BODY_KEYS = ["batchId", "changes"] as const;
export const CHANGE_KEYS = [
  "changeId",
  "bookId",
  "kind",
  "id",
  "baseVersion",
  "deleted",
  "clientTime",
  "payload",
] as const;
export const REGISTER_BOOK_KEYS = ["sha256", "size", "format", "docId", "title", "filename"] as const;
export const REDEEM_KEYS = ["token", "deviceId", "name", "platform", "appVersion"] as const;
