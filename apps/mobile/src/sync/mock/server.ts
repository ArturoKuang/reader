/**
 * In-process sync server for spec rev 3.
 * The phone client talks to it through `fetch`. Nothing here is the Mac app.
 */

import { isHighlightColor } from "../../contract/types";
import { canonicalJson, clone, sameRecord, utf8Size } from "../canonical";
import { assertBookId, invalidRecordId, kindOfClient, normalizeWord } from "../ids";
import {
  CHANGE_KEYS,
  LIMITS,
  PROTOCOL_VERSION,
  PUSH_BODY_KEYS,
  REDEEM_KEYS,
  REGISTER_BOOK_KEYS,
  type ApiErrorBody,
  type BookListItem,
  type BookPayload,
  type ChangeInput,
  type ChangeResult,
  type ClientKind,
  type ConflictSide,
  type DeviceKind,
  type Envelope,
  type ErrorCode,
  type HealthResponse,
  type JsonObject,
  type OpenConflict,
  type PushRequest,
  type PushResponse,
  type RecordKind,
} from "../wire";

interface StoredDevice {
  deviceId: string;
  name: string;
  platform: string;
  kind: DeviceKind;
  credential: string;
}

interface VersionSnap {
  deleted: boolean;
  payload: JsonObject;
}

interface StoredRecord {
  bookId: string;
  kind: RecordKind;
  id: string;
  version: number;
  baseVersion: number;
  deleted: boolean;
  payload: JsonObject;
  deviceId: string;
  changeId: string;
  clientTime: string;
  seq: number;
  history: Map<number, VersionSnap>;
  conflict: OpenConflict | null;
}

interface StoredBook {
  bookId: string;
  title: string;
  filename: string;
  format: string;
  docId?: string;
  currentSha256: string;
  files: { sha256: string; size: number; addedAt: string }[];
  version: number;
  seq: number;
}

interface StoredChange {
  canonical: string;
  result: ChangeResult;
}

interface StoredBatch {
  canonical: string;
  response: PushResponse;
}

function stripReaderPrefix(pathname: string): string {
  const prefix = "/v1/reader";
  if (pathname === prefix) return "/";
  if (pathname.startsWith(`${prefix}/`)) return pathname.slice(prefix.length);
  return pathname;
}

/** Kind is part of the key, so a note and its highlight may share an id. */
function recordKey(bookId: string, kind: string, id: string): string {
  return `${bookId}\u0000${kind}\u0000${id}`;
}

function unknownKeys(value: object, allowed: readonly string[]): string[] {
  return Object.keys(value).filter((key) => !allowed.includes(key));
}

type ParsedChange = Omit<ChangeInput, "kind"> & { kind: ClientKind | "book" };

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class MockSyncServer {
  serverId: string;
  serverVersion = "0.0.0-mock";
  seq = 0;
  /** When true, fetch fails before the handler runs. */
  offline = false;
  /** PUT /v1/blobs returns HTTP 507. Record routes keep working. */
  diskFull = false;
  fullCode: "disk_full" | "quota_exceeded" = "disk_full";
  /** Completed requests whose Response is dropped. State changes stick. */
  loseResponses = 0;
  readonly seenRequests: { method: string; path: string; host: string }[] = [];
  readonly appliedChanges: ParsedChange[] = [];
  /** Every accepted push body, including idempotent replays. */
  readonly pushes: PushRequest[] = [];

  private devices = new Map<string, StoredDevice>();
  private credentials = new Map<string, StoredDevice>();
  private tokens = new Map<string, { deviceId?: string }>();
  private books = new Map<string, StoredBook>();
  private blobs = new Map<string, Uint8Array>();
  private records = new Map<string, StoredRecord>();
  private batches = new Map<string, StoredBatch>();
  private changes = new Map<string, StoredChange>();
  private resolvedConflicts = new Set<string>();
  private nowIso: () => string;

  constructor(options?: { serverId?: string; now?: () => string }) {
    this.serverId = options?.serverId ?? "srv_mock";
    this.nowIso = options?.now ?? (() => new Date(0).toISOString());
  }

  pairDevice(input: { deviceId: string; name: string; platform: string; kind: DeviceKind }): string {
    const credential = `cred_${input.deviceId}_${this.credentials.size + 1}`;
    const device: StoredDevice = { ...input, credential };
    this.devices.set(input.deviceId, device);
    this.credentials.set(credential, device);
    return credential;
  }

  issueToken(token: string): void {
    this.tokens.set(token, {});
  }

  putBlob(sha256: string, bytes: Uint8Array): void {
    this.blobs.set(sha256, bytes);
  }

  forgetBook(bookId: string): void {
    this.books.delete(bookId);
    const prefix = `${bookId}\u0000book\u0000`;
    for (const key of this.records.keys()) {
      if (key.startsWith(prefix)) this.records.delete(key);
    }
  }

  record(bookId: string, kind: RecordKind, id: string): StoredRecord | undefined {
    return this.records.get(recordKey(bookId, kind, id));
  }

  async fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    if (this.offline) throw new TypeError("network unavailable");
    const request = new Request(input, init);
    const url = new URL(request.url);
    this.seenRequests.push({ method: request.method, path: url.pathname + url.search, host: url.host });
    const response = await this.route(request, url);
    if (this.loseResponses > 0) {
      this.loseResponses -= 1;
      throw new TypeError("socket reset after the server applied the request");
    }
    return response;
  }

  private async route(request: Request, url: URL): Promise<Response> {
    const path = stripReaderPrefix(url.pathname);
    if (request.method === "GET" && path === "/v1/health") return this.json(this.health());
    if (request.method === "POST" && path === "/v1/pairing/redeem") {
      return this.redeem(await this.readJson(request));
    }

    const device = this.authenticate(request);
    if (!device) return this.fail(401, "unauthorized", "missing or unknown credential");

    if (request.method === "GET" && path === "/v1/devices") {
      return this.json({
        devices: [...this.devices.values()].map((item) => ({
          deviceId: item.deviceId,
          name: item.name,
          platform: item.platform,
          kind: item.kind,
        })),
      });
    }
    if (request.method === "GET" && path === "/v1/books") return this.json({ books: this.bookList() });
    if (request.method === "POST" && (path === "/v1/books/register" || path === "/v1/books")) {
      return this.registerBook(device, await this.readJson(request));
    }
    if (request.method === "POST" && path === "/v1/changes") {
      const raw = await request.text();
      if (utf8Size(raw) > LIMITS.maxBatchBytes) return this.fail(413, "too_large", "batch exceeds 8 MiB");
      let body: unknown;
      try {
        body = JSON.parse(raw);
      } catch {
        return this.fail(400, "bad_request", "body is not JSON");
      }
      return this.push(device, body);
    }
    if (request.method === "GET" && path === "/v1/changes") return this.pull(url);
    if (request.method === "GET" && path === "/v1/conflicts") return this.listConflicts(url);
    const resolve = path.match(/^\/v1\/conflicts\/([^/]+)\/resolve$/);
    if (request.method === "POST" && resolve) {
      return this.resolveConflict(device, decodeURIComponent(resolve[1]));
    }
    const blob = path.match(/^\/v1\/blobs\/([0-9a-f]{64})$/);
    if (request.method === "PUT" && blob) return this.writeBlob(blob[1], request);
    if (request.method === "GET" && blob) return this.readBlob(blob[1], request);
    return this.fail(404, "not_found", `no route ${request.method} ${path}`);
  }

  private async writeBlob(sha256: string, request: Request): Promise<Response> {
    if (this.diskFull) return this.fail(507, this.fullCode, "the Mac mini has no room for this book");
    const bytes = new Uint8Array(await request.arrayBuffer());
    this.blobs.set(sha256, bytes);
    return this.json({ ok: true, sha256 });
  }

  private health(): HealthResponse {
    return {
      ok: true,
      serverId: this.serverId,
      serverVersion: this.serverVersion,
      protocol: PROTOCOL_VERSION,
      seq: this.seq,
    };
  }

  private authenticate(request: Request): StoredDevice | null {
    const header = request.headers.get("authorization") ?? "";
    const match = /^Bearer (.+)$/.exec(header);
    if (!match) return null;
    return this.credentials.get(match[1]) ?? null;
  }

  private async readJson(request: Request): Promise<unknown> {
    const text = await request.text();
    if (text.length === 0) return {};
    return JSON.parse(text) as unknown;
  }

  private redeem(body: unknown): Response {
    if (!isObject(body)) return this.fail(400, "bad_request", "redeem body must be an object");
    const extra = unknownKeys(body, REDEEM_KEYS);
    if (extra.length > 0) return this.fail(400, "bad_request", `unknown field ${extra[0]}`);
    const token = body.token;
    const deviceId = body.deviceId;
    const name = body.name;
    const platform = body.platform;
    const appVersion = body.appVersion;
    if (
      typeof token !== "string" ||
      typeof deviceId !== "string" ||
      typeof name !== "string" ||
      typeof platform !== "string" ||
      typeof appVersion !== "string"
    ) {
      return this.fail(400, "bad_request", "redeem fields must be strings");
    }
    const issued = this.tokens.get(token);
    if (!issued) return this.fail(403, "forbidden", "unknown pairing token");
    if (issued.deviceId && issued.deviceId !== deviceId) {
      return this.fail(403, "forbidden", "pairing token is bound to another device");
    }
    const existing = this.devices.get(deviceId);
    if (existing) this.credentials.delete(existing.credential);
    const kind: DeviceKind = platform === "mac" ? "mac" : "phone";
    const credential = this.pairDevice({ deviceId, name, platform, kind });
    issued.deviceId = deviceId;
    const saved = this.devices.get(deviceId);
    if (saved) saved.credential = credential;
    return this.json({ deviceId, credential, serverId: this.serverId, kind });
  }

  private registerBook(device: StoredDevice, body: unknown): Response {
    if (!isObject(body)) return this.fail(400, "bad_request", "book body must be an object");
    const extra = unknownKeys(body, REGISTER_BOOK_KEYS);
    if (extra.length > 0) return this.fail(400, "bad_request", `unknown field ${extra[0]}`);
    const sha256 = body.sha256;
    const size = body.size;
    const format = body.format;
    const title = body.title;
    const filename = body.filename;
    const docId = body.docId;
    if (typeof sha256 !== "string" || !/^[0-9a-f]{64}$/.test(sha256)) {
      return this.fail(400, "bad_request", "sha256 must be 64 lowercase hex digits");
    }
    if (typeof size !== "number" || !Number.isInteger(size) || size < 0) {
      return this.fail(400, "bad_request", "size must be a non-negative integer");
    }
    if (typeof format !== "string" || typeof title !== "string" || typeof filename !== "string") {
      return this.fail(400, "bad_request", "format, title, and filename are required");
    }
    if (docId !== undefined && typeof docId !== "string") return this.fail(400, "bad_request", "docId must be a string");

    const bySha = [...this.books.values()].find((book) => book.files.some((file) => file.sha256 === sha256));
    if (bySha) return this.json({ status: "existing", bookId: bySha.bookId, book: this.projectBook(bySha) });

    const byDoc = docId ? [...this.books.values()].find((book) => book.docId === docId) : undefined;
    if (byDoc) {
      byDoc.files.push({ sha256, size, addedAt: this.nowIso() });
      byDoc.currentSha256 = sha256;
      byDoc.title = title;
      byDoc.filename = filename;
      byDoc.format = format;
      this.bumpBookRecord(device, byDoc);
      return this.json({ status: "attached", bookId: byDoc.bookId, book: this.projectBook(byDoc) });
    }

    const bookId = `sha256:${sha256}`;
    const created: StoredBook = {
      bookId,
      title,
      filename,
      format,
      docId: typeof docId === "string" ? docId : undefined,
      currentSha256: sha256,
      files: [{ sha256, size, addedAt: this.nowIso() }],
      version: 0,
      seq: 0,
    };
    this.books.set(bookId, created);
    this.bumpBookRecord(device, created);
    return this.json({ status: "created", bookId, book: this.projectBook(created) });
  }

  private bumpBookRecord(device: StoredDevice, book: StoredBook): void {
    this.seq += 1;
    book.version += 1;
    book.seq = this.seq;
    const payload: BookPayload = {
      title: book.title,
      filename: book.filename,
      format: book.format,
      files: book.files.map((file) => ({ ...file })),
      currentSha256: book.currentSha256,
      extras: {},
    };
    if (book.docId) payload.docId = book.docId;
    const key = recordKey(book.bookId, "book", book.bookId);
    const previous = this.records.get(key);
    const history = previous?.history ?? new Map<number, VersionSnap>();
    const stored: StoredRecord = {
      bookId: book.bookId,
      kind: "book",
      id: book.bookId,
      version: book.version,
      baseVersion: previous ? previous.version : 0,
      deleted: false,
      payload: payload as unknown as JsonObject,
      deviceId: device.deviceId,
      changeId: `book_${book.version}`,
      clientTime: this.nowIso(),
      seq: this.seq,
      history,
      conflict: previous?.conflict ?? null,
    };
    history.set(stored.version, { deleted: false, payload: clone(stored.payload) });
    this.records.set(key, stored);
  }

  private bookList(): BookListItem[] {
    return [...this.books.values()].map((book) => this.projectBook(book));
  }

  private projectBook(book: StoredBook): BookListItem {
    const current = book.files.find((file) => file.sha256 === book.currentSha256) ?? book.files[book.files.length - 1];
    return {
      bookId: book.bookId,
      title: book.title,
      filename: book.filename,
      format: book.format,
      docId: book.docId,
      sha256: book.currentSha256,
      size: current?.size ?? 0,
      hasBlob: this.blobs.has(book.currentSha256),
      files: book.files.map((file) => ({
        sha256: file.sha256,
        size: file.size,
        hasBlob: this.blobs.has(file.sha256),
      })),
      version: book.version,
      seq: book.seq,
    };
  }

  private push(device: StoredDevice, body: unknown): Response {
    if (!isObject(body)) return this.fail(400, "bad_request", "batch must be an object");
    const extra = unknownKeys(body, PUSH_BODY_KEYS);
    if (extra.length > 0) return this.fail(400, "bad_request", `unknown field ${extra[0]}`);
    if (typeof body.batchId !== "string" || !Array.isArray(body.changes)) {
      return this.fail(400, "bad_request", "batchId and changes are required");
    }
    if (invalidRecordId(body.batchId)) return this.fail(400, "bad_request", "batchId is not a valid id");
    if (body.changes.length > LIMITS.maxChangesPerBatch) {
      return this.fail(413, "too_large", "a batch holds at most 500 changes");
    }
    const parsed: ParsedChange[] = [];
    const seenKeys = new Set<string>();
    for (const raw of body.changes) {
      const change = this.parseChange(raw);
      if ("error" in change) return this.fail(change.status, change.code, change.message);
      const key = recordKey(change.bookId, change.kind, change.id);
      if (seenKeys.has(key)) return this.fail(400, "bad_request", "a batch may change each record once");
      seenKeys.add(key);
      parsed.push(change);
    }
    if (parsed.some((change) => change.kind === "book")) {
      return this.fail(400, "use_register", "register books with POST /v1/books/register");
    }
    const request: PushRequest = { batchId: body.batchId, changes: parsed as ChangeInput[] };
    const canonical = canonicalJson(request);
    this.pushes.push(clone(request));
    const stored = this.batches.get(request.batchId);
    if (stored) {
      if (stored.canonical === canonical) return this.json(clone(stored.response));
      return this.fail(422, "change_id_reused", "batchId was already used with a different body");
    }

    const results: ChangeResult[] = [];
    for (const change of parsed) {
      const changeCanonical = canonicalJson(change);
      const prior = this.changes.get(change.changeId);
      if (prior) {
        if (prior.canonical === changeCanonical) {
          results.push(clone(prior.result));
          continue;
        }
        const rejected = this.rejected(change.changeId, "change_id_reused", "changeId was already used with a different body");
        this.changes.set(change.changeId, { canonical: changeCanonical, result: rejected });
        results.push(rejected);
        continue;
      }
      const result = this.applyChange(device, change);
      this.changes.set(change.changeId, { canonical: changeCanonical, result: clone(result) });
      results.push(result);
    }
    const response: PushResponse = { batchId: request.batchId, seq: this.seq, results };
    this.batches.set(request.batchId, { canonical, response: clone(response) });
    return this.json(response);
  }

  private parseChange(raw: unknown): ParsedChange | { error: true; status: number; code: ErrorCode; message: string } {
    if (!isObject(raw)) return { error: true, status: 400, code: "bad_request", message: "change must be an object" };
    const extra = unknownKeys(raw, CHANGE_KEYS);
    if (extra.length > 0) return { error: true, status: 400, code: "bad_request", message: `unknown field ${extra[0]}` };
    const { changeId, bookId, kind, id, baseVersion, deleted, clientTime, payload } = raw;
    if (typeof changeId !== "string" || invalidRecordId(changeId)) {
      return { error: true, status: 400, code: "bad_request", message: "changeId is invalid" };
    }
    if (typeof bookId !== "string" || !assertBookId(bookId)) {
      return { error: true, status: 400, code: "bad_request", message: "bookId must be sha256: plus 64 hex digits" };
    }
    if (typeof kind !== "string" || (kind !== "book" && !kindOfClient(kind))) {
      return { error: true, status: 400, code: "bad_request", message: "unknown kind" };
    }
    if (typeof id !== "string" || invalidRecordId(id)) {
      return { error: true, status: 400, code: "bad_request", message: "id is invalid" };
    }
    if (typeof baseVersion !== "number" || !Number.isInteger(baseVersion) || baseVersion < 0) {
      return { error: true, status: 400, code: "bad_request", message: "baseVersion must be a non-negative integer" };
    }
    if (typeof deleted !== "boolean") return { error: true, status: 400, code: "bad_request", message: "deleted must be boolean" };
    if (typeof clientTime !== "string") return { error: true, status: 400, code: "bad_request", message: "clientTime must be a string" };
    if (!isObject(payload)) return { error: true, status: 400, code: "bad_request", message: "payload must be an object" };
    if (!isObject(payload.extras)) return { error: true, status: 400, code: "bad_request", message: "payload.extras is required" };
    if (utf8Size(JSON.stringify(payload)) > LIMITS.maxPayloadBytes) {
      return { error: true, status: 413, code: "too_large", message: "payload exceeds 1 MiB" };
    }
    return {
      changeId,
      bookId,
      kind: kind as ParsedChange["kind"],
      id,
      baseVersion,
      deleted,
      clientTime,
      payload: payload as JsonObject,
    };
  }

  private applyChange(device: StoredDevice, change: ParsedChange): ChangeResult {
    if (change.kind === "book") return this.rejected(change.changeId, "use_register", "book records are written by register");
    if (!this.books.has(change.bookId)) return this.rejected(change.changeId, "unknown_book", "register the book before pushing records");
    if (change.kind === "position") return this.applyPosition(device, change);
    const payloadError = this.validatePayload(change);
    if (payloadError) return this.rejected(change.changeId, "bad_request", payloadError);

    const key = recordKey(change.bookId, change.kind, change.id);
    const head = this.records.get(key);
    if (!head) {
      if (change.baseVersion !== 0) return this.rejected(change.changeId, "bad_base", "create requires baseVersion 0");
      return this.writeRecord(device, change, null, 1);
    }
    if (change.baseVersion > head.version) return this.rejected(change.changeId, "bad_base", "baseVersion is ahead of the head");
    if (sameRecord(change, head)) return this.noop(change.changeId, head);
    if (change.baseVersion === head.version) return this.writeRecord(device, change, head, head.version + 1);
    if (head.conflict && head.conflict.sides.some((side) => sameRecord(change, side))) {
      return this.noop(change.changeId, head);
    }
    return this.openConflict(device, change, head);
  }

  private applyPosition(device: StoredDevice, change: ParsedChange): ChangeResult {
    if (change.deleted) return this.rejected(change.changeId, "bad_request", "positions are not deleted");
    const payloadError = this.validatePosition(device, change);
    if (payloadError) return this.rejected(change.changeId, payloadError === "not_owner" ? "not_owner" : "bad_request", payloadError === "not_owner" ? "only the owning device may write this position" : payloadError);
    const head = this.records.get(recordKey(change.bookId, "position", change.id));
    if (head && sameRecord(change, head)) return this.noop(change.changeId, head);
    const version = head ? head.version + 1 : 1;
    return this.writeRecord(device, change, head ?? null, version);
  }

  private validatePosition(device: StoredDevice, change: ParsedChange): string | null {
    const expected = `p_${change.bookId}_${device.deviceId}`;
    const payload = change.payload;
    if (change.id !== expected || payload.bookId !== change.bookId || payload.deviceId !== device.deviceId) {
      return "not_owner";
    }
    const locator = payload.locator;
    if (!isObject(locator)) return "locator is required";
    if (locator.format === "pdf") {
      if (typeof locator.page !== "number" || !Number.isInteger(locator.page) || locator.page < 1) {
        return "pdf locator page must be an integer >= 1";
      }
      if (locator.point !== undefined) {
        if (!isObject(locator.point) || typeof locator.point.x !== "number" || typeof locator.point.y !== "number") {
          return "pdf point must be {x, y}";
        }
      }
      return null;
    }
    if (locator.format === "epub") {
      if (typeof locator.cfi !== "string" || locator.cfi.length === 0) return "epub locator needs a cfi";
      if (locator.progression !== undefined) {
        if (typeof locator.progression !== "number" || locator.progression < 0 || locator.progression > 1) {
          return "epub progression must be between 0 and 1";
        }
      }
      return null;
    }
    return "locator.format must be pdf or epub";
  }

  private validatePayload(change: ParsedChange): string | null {
    if (change.kind === "word") {
      const word = change.payload.word;
      if (typeof word !== "string") return "word payload needs word";
      if (change.id !== `w_${normalizeWord(word)}`) return "word id must be w_ plus normalizeWord(word)";
      if ("lookups" in change.payload) return "word payload must not include lookups";
    }
    if (change.kind === "highlight") {
      const color = change.payload.color;
      if (typeof color !== "number" || !isHighlightColor(color)) return "highlight color must be 1 through 6";
      if ("noteId" in change.payload) return "highlight payload must not include noteId";
    }
    return null;
  }

  private writeRecord(device: StoredDevice, change: ParsedChange, head: StoredRecord | null, version: number): ChangeResult {
    this.seq += 1;
    const history = head?.history ?? new Map<number, VersionSnap>();
    const stored: StoredRecord = {
      bookId: change.bookId,
      kind: change.kind,
      id: change.id,
      version,
      baseVersion: change.baseVersion,
      deleted: change.deleted,
      payload: clone(change.payload),
      deviceId: device.deviceId,
      changeId: change.changeId,
      clientTime: change.clientTime,
      seq: this.seq,
      history,
      conflict: null,
    };
    history.set(version, { deleted: stored.deleted, payload: clone(stored.payload) });
    this.records.set(recordKey(change.bookId, change.kind, change.id), stored);
    this.appliedChanges.push(clone(change));
    return { changeId: change.changeId, status: "applied", version, seq: this.seq };
  }

  private noop(changeId: string, head: StoredRecord): ChangeResult {
    return { changeId, status: "noop", version: head.version, seq: head.seq };
  }

  private openConflict(device: StoredDevice, change: ParsedChange, head: StoredRecord): ChangeResult {
    this.seq += 1;
    const incoming: ConflictSide = {
      changeId: change.changeId,
      deviceId: device.deviceId,
      version: null,
      deleted: change.deleted,
      payload: clone(change.payload),
      clientTime: change.clientTime,
    };
    if (!head.conflict) {
      const baseSnap = head.history.get(change.baseVersion) ?? null;
      const headSide: ConflictSide = {
        changeId: head.changeId,
        deviceId: head.deviceId,
        version: head.version,
        deleted: head.deleted,
        payload: clone(head.payload),
        clientTime: head.clientTime,
      };
      head.conflict = {
        conflictId: `c_${this.seq}`,
        bookId: head.bookId,
        kind: head.kind,
        id: head.id,
        baseVersion: change.baseVersion,
        base: baseSnap ? { deleted: baseSnap.deleted, payload: clone(baseSnap.payload) } : null,
        sides: [headSide, incoming],
        openedSeq: this.seq,
      };
    } else {
      head.conflict.sides.push(incoming);
    }
    head.seq = this.seq;
    return {
      changeId: change.changeId,
      status: "conflict",
      version: head.version,
      seq: this.seq,
      conflictId: head.conflict.conflictId,
    };
  }

  private pull(url: URL): Response {
    const sinceText = url.searchParams.get("since") ?? "0";
    const limitText = url.searchParams.get("limit") ?? String(LIMITS.maxPullLimit);
    const since = Number(sinceText);
    const limit = Number(limitText);
    if (!Number.isInteger(since) || since < 0) return this.fail(400, "bad_request", "since must be a non-negative integer");
    if (!Number.isInteger(limit) || limit < 1 || limit > LIMITS.maxPullLimit) {
      return this.fail(400, "bad_request", "limit must be 1 through 1000");
    }
    const matching = [...this.records.values()]
      .filter((record) => record.seq > since)
      .sort((left, right) => left.seq - right.seq);
    const page = matching.slice(0, limit);
    const hasMore = matching.length > page.length;
    const cursor = hasMore ? page[page.length - 1].seq : Math.max(since, this.seq);
    return this.json({
      changes: page.map((record) => this.envelope(record)),
      cursor,
      hasMore,
      serverId: this.serverId,
    });
  }

  private envelope(record: StoredRecord): Envelope {
    const envelope: Envelope = {
      bookId: record.bookId,
      kind: record.kind,
      id: record.id,
      version: record.version,
      baseVersion: record.baseVersion,
      deleted: record.deleted,
      deviceId: record.deviceId,
      changeId: record.changeId,
      clientTime: record.clientTime,
      seq: record.seq,
      payload: clone(record.payload),
    };
    if (record.conflict) envelope.conflict = clone(record.conflict);
    return envelope;
  }

  private listConflicts(url: URL): Response {
    const bookId = url.searchParams.get("bookId");
    const conflicts = [...this.records.values()]
      .map((record) => record.conflict)
      .filter((conflict): conflict is OpenConflict => conflict !== null)
      .filter((conflict) => (bookId ? conflict.bookId === bookId : true))
      .map((conflict) => clone(conflict));
    return this.json({ conflicts });
  }

  private resolveConflict(device: StoredDevice, conflictId: string): Response {
    if (device.kind !== "mac") {
      return this.fail(403, "forbidden", "the phone displays conflicts; Reader on the Mac resolves them");
    }
    if (this.resolvedConflicts.has(conflictId)) {
      return this.fail(409, "already_resolved", "conflict is already resolved");
    }
    const owner = [...this.records.values()].find((record) => record.conflict?.conflictId === conflictId);
    if (!owner || !owner.conflict) return this.fail(404, "not_found", "unknown conflict");
    this.resolvedConflicts.add(conflictId);
    owner.conflict = null;
    this.seq += 1;
    owner.seq = this.seq;
    return this.json({ ok: true, conflictId, seq: this.seq });
  }

  private readBlob(sha256: string, request: Request): Response {
    const bytes = this.blobs.get(sha256);
    if (!bytes) return this.fail(404, "not_found", "blob not found");
    const etag = `"${sha256}"`;
    const ifRange = request.headers.get("if-range");
    const range = request.headers.get("range");
    const honorRange = range !== null && (ifRange === null || ifRange === etag);
    let start = 0;
    let end = bytes.length - 1;
    if (honorRange && range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (!match) return this.fail(416, "range_not_satisfiable", "only a single bytes range is supported");
      start = Number(match[1]);
      end = match[2] === "" ? bytes.length - 1 : Number(match[2]);
      if (start > end || start >= bytes.length) {
        return this.fail(416, "range_not_satisfiable", "range is outside the blob", {
          "content-range": `bytes */${bytes.length}`,
        });
      }
      end = Math.min(end, bytes.length - 1);
    }
    const slice = bytes.slice(start, end + 1);
    const status = honorRange && range ? 206 : 200;
    const headers: Record<string, string> = {
      etag,
      "accept-ranges": "bytes",
      "content-type": "application/octet-stream",
    };
    if (status === 206) headers["content-range"] = `bytes ${start}-${end}/${bytes.length}`;
    return new Response(slice, { status, headers });
  }

  private rejected(changeId: string, code: string, message: string): ChangeResult {
    return { changeId, status: "rejected", error: { code, message } };
  }

  private json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  private fail(status: number, code: ErrorCode, message: string, extraHeaders?: Record<string, string>): Response {
    const body: ApiErrorBody = { error: { code, message } };
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json", ...extraHeaders },
    });
  }
}
