import type { HighlightRecord, LookupRecord, NoteRecord, WordRecord } from "../contract/types";
import { clone } from "./canonical";
import type { Clock, TimerHandle } from "./clock";
import { CREDENTIAL_KEY, type CredentialStore } from "./credentials";
import { bookIdForSha, positionId } from "./ids";
import { chooseBlobFile, downloadBookBlob } from "./blobs";
import { parsePairingUrl } from "./pairing";
import { highlightToPayload, lookupToPayload, noteToPayload, positionToPayload, wordToPayload } from "./payload";
import {
  emptyPersisted,
  type LocalRecord,
  type OutboxBatch,
  type OutboxChange,
  type PersistedSync,
  type StoredPosition,
  type SyncStorage,
} from "./storage";
import {
  deriveSyncStatus,
  ERROR_AFTER_MS,
  POSITION_SETTLE_MS,
  POSITION_TOAST_MS,
  PULL_INTERVAL_MS,
  type SyncStatus,
} from "./status";
import { SyncApiError, SyncNetworkError, type SyncTransport } from "./transport";
import type {
  ChangeInput,
  ClientKind,
  DeviceInfo,
  Envelope,
  JsonObject,
  Locator,
  BookListItem,
  OpenConflict,
  PullResponse,
  PushResponse,
  RegisterBookRequest,
} from "./wire";

const BACKOFF_START_MS = 1_000;
const BACKOFF_CAP_MS = 30_000;

export interface SyncDevice {
  deviceId: string;
  name: string;
  platform: string;
  appVersion: string;
}

export interface EngineSession {
  /** `http://host:port` from the pairing QR. Never a built-in default. */
  baseUrl: string | null;
  credential: string | null;
}

export interface EngineDeps {
  transport: SyncTransport;
  storage: SyncStorage;
  credentials: CredentialStore;
  clock: Clock;
  device: SyncDevice;
  session: EngineSession;
  pullLimit?: number;
}

export interface ReadingPlace {
  /** PDF page the reader is already showing. */
  page?: number;
  /** EPUB chapter key, `epubChapterKey(cfi)`. */
  chapterKey?: string;
}

export interface ResumeOffer {
  bookId: string;
  locator: Locator;
  deviceId: string;
  deviceName: string;
  seq: number;
  /** Full sentence. Null when the toast stays hidden. */
  toast: string | null;
  toastLead: string | null;
  toastAction: string | null;
  toastDurationMs: number;
}

function newId(): string {
  return globalThis.crypto.randomUUID();
}

function sameKey(change: { bookId: string; kind: string; id: string }, record: { bookId: string; kind: string; id: string }): boolean {
  return change.bookId === record.bookId && change.kind === record.kind && change.id === record.id;
}

/** Spine path before `!`. Two CFIs in one chapter share it. */
export function epubChapterKey(cfi: string): string {
  const inner = cfi.startsWith("epubcfi(") ? cfi.slice("epubcfi(".length).replace(/\)$/, "") : cfi;
  const bang = inner.indexOf("!");
  return bang >= 0 ? inner.slice(0, bang) : inner;
}

function isRetryable(error: unknown): boolean {
  if (error instanceof SyncNetworkError) return true;
  if (error instanceof SyncApiError && (error.status === 503 || error.status >= 500)) return true;
  return false;
}

function locatorOf(payload: JsonObject): Locator | null {
  const locator = payload.locator;
  if (!locator || typeof locator !== "object" || Array.isArray(locator)) return null;
  const record = locator as { format?: string; page?: number; cfi?: string; progression?: number; point?: { x: number; y: number } };
  if (record.format === "pdf" && typeof record.page === "number") {
    return { format: "pdf", page: record.page, point: record.point };
  }
  if (record.format === "epub" && typeof record.cfi === "string") {
    return {
      format: "epub",
      cfi: record.cfi,
      progression: typeof record.progression === "number" ? record.progression : undefined,
    };
  }
  return null;
}

/**
 * One sync engine. Transport, storage, and clock are injected.
 * The phone displays conflicts and does not resolve them.
 */
export class SyncEngine {
  private state: PersistedSync = emptyPersisted();
  private flight = 0;
  private active = false;
  private attempts = 0;
  private flushing: Promise<void> | null = null;
  private positionWait: { bookId: string; locator: Locator } | null = null;
  private readonly opened = new Map<string, ResumeOffer>();
  private listed: BookListItem[] = [];
  private readonly listeners = new Set<(status: SyncStatus) => void>();
  private pullTimer: TimerHandle | null = null;
  private backoffTimer: TimerHandle | null = null;
  private errorTimer: TimerHandle | null = null;
  private flushTimer: TimerHandle | null = null;
  private positionTimer: TimerHandle | null = null;
  private readonly pausedBytes = new Map<string, Uint8Array>();

  constructor(private readonly deps: EngineDeps) {}

  /** Origin currently in use. Null until a QR has been redeemed or restored. */
  origin(): string | null {
    return this.deps.session.baseUrl;
  }

  status(): SyncStatus {
    const pendingCount =
      (this.state.inflight?.changes.length ?? 0) +
      (this.state.pending?.changes.length ?? 0) +
      (this.positionWait ? 1 : 0);
    return deriveSyncStatus({
      pendingCount,
      conflictCount: this.state.conflicts.length,
      lastSyncedAt: this.state.lastSyncedAt,
      inFlight: this.flight > 0,
      failureStartedAt: this.state.failureStartedAt,
      storageFull: this.state.storageFull,
      pausedBookIds: this.state.pausedBookIds,
      now: this.deps.clock.now(),
    });
  }

  /** True once a v=2 pairing has been redeemed and credentials restored. */
  isPaired(): boolean {
    return Boolean(this.deps.session.credential && this.deps.session.baseUrl);
  }

  /** Local highlight, note, word, and lookup records for one book. */
  recordsFor(bookId: string): LocalRecord[] {
    return this.state.records.filter((record) => record.bookId === bookId);
  }

  subscribe(listener: (status: SyncStatus) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  /** Open conflicts for the read-only card. There is no resolve method. */
  openConflicts(): OpenConflict[] {
    return clone(this.state.conflicts);
  }

  conflictsFor(bookId: string, kind: ClientKind, id: string): OpenConflict | null {
    return this.state.conflicts.find((conflict) => conflict.bookId === bookId && conflict.kind === kind && conflict.id === id) ?? null;
  }

  /**
   * Resume offer captured by `openBook`. Pull never replaces it.
   * Mid-session position envelopes stay in storage until the next open.
   */
  sessionResume(bookId: string): ResumeOffer | null {
    return this.opened.get(bookId) ?? null;
  }

  async pair(qr: string) {
    const parts = parsePairingUrl(qr);
    this.deps.session.baseUrl = parts.url;
    const redeemed = await this.deps.transport.redeem({
      token: parts.token,
      deviceId: this.deps.device.deviceId,
      name: this.deps.device.name,
      platform: this.deps.device.platform,
      appVersion: this.deps.device.appVersion,
    });
    this.deps.session.credential = redeemed.credential;
    await this.deps.credentials.set(CREDENTIAL_KEY, redeemed.credential);
    this.state.baseUrl = parts.url;
    if (this.state.serverId && this.state.serverId !== redeemed.serverId) {
      this.resetForNewServer(redeemed.serverId);
    } else {
      this.state.serverId = redeemed.serverId;
    }
    this.rememberDevice({
      deviceId: redeemed.deviceId,
      name: this.deps.device.name,
      platform: this.deps.device.platform,
      kind: redeemed.kind,
    });
    await this.persist();
    this.emit();
    return redeemed;
  }

  async start(): Promise<void> {
    const loaded = await this.deps.storage.load();
    if (loaded) this.state = loaded;
    this.deps.session.credential = await this.deps.credentials.get(CREDENTIAL_KEY);
    if (this.state.baseUrl) this.deps.session.baseUrl = this.state.baseUrl;
    this.active = true;
    if (!this.deps.session.credential || !this.deps.session.baseUrl) {
      this.emit();
      return;
    }
    await this.recheckStorage();
    await this.flush();
    await this.pull();
    this.armPull();
  }

  stop(): void {
    this.active = false;
    this.pullTimer?.cancel();
    this.backoffTimer?.cancel();
    this.flushTimer?.cancel();
    this.positionTimer?.cancel();
    this.errorTimer?.cancel();
  }

  async onForeground(): Promise<void> {
    this.active = true;
    await this.recheckStorage();
    await this.flush();
    await this.pull();
    this.armPull();
  }

  async onBackground(): Promise<void> {
    this.active = false;
    this.pullTimer?.cancel();
    await this.flushPositionNow();
  }

  /**
   * Upload a book file. HTTP 507 disk_full or quota_exceeded pauses that book
   * and does not retry. Record push, pull, and register keep running.
   */
  async uploadBook(bookId: string, bytes: Uint8Array): Promise<"uploaded" | "paused"> {
    const book = this.state.books.find((item) => item.bookId === bookId);
    if (!book) throw new SyncApiError(400, "unknown_book", `missing local book ${bookId}`);
    this.pausedBytes.set(bookId, bytes);
    try {
      await this.deps.transport.uploadBlob(book.sha256, bytes);
    } catch (error) {
      if (!isStorageFull(error)) throw error;
      this.state.storageFull = true;
      if (!this.state.pausedBookIds.includes(bookId)) this.state.pausedBookIds.push(bookId);
      await this.persist();
      this.emit();
      return "paused";
    }
    this.clearPaused(bookId);
    await this.persist();
    this.emit();
    return "uploaded";
  }

  /** Try paused uploads again. A successful upload clears storageFull. */
  async recheckStorage(): Promise<void> {
    if (!this.state.storageFull && this.state.pausedBookIds.length === 0) return;
    for (const bookId of [...this.state.pausedBookIds]) {
      const bytes = this.pausedBytes.get(bookId);
      const book = this.state.books.find((item) => item.bookId === bookId);
      if (!bytes || !book) continue;
      try {
        await this.deps.transport.uploadBlob(book.sha256, bytes);
        this.clearPaused(bookId);
      } catch (error) {
        if (isStorageFull(error)) {
          this.state.storageFull = true;
          continue;
        }
        if (isRetryable(error)) continue;
        throw error;
      }
    }
    if (this.state.pausedBookIds.length === 0) this.state.storageFull = false;
    await this.persist();
    this.emit();
  }

  /** Error-chip action. Sends the same outbox ids immediately. */
  async retryNow(): Promise<void> {
    this.backoffTimer?.cancel();
    this.attempts = 0;
    await this.flush();
  }

  async trackBook(input: RegisterBookRequest): Promise<string> {
    const provisional = bookIdForSha(input.sha256);
    let book = this.state.books.find((item) => item.bookId === provisional || (input.docId !== undefined && item.docId === input.docId));
    if (!book) {
      book = {
        bookId: provisional,
        sha256: input.sha256,
        size: input.size,
        format: input.format,
        docId: input.docId,
        title: input.title,
        filename: input.filename,
        registeredForServerId: null,
      };
      this.state.books.push(book);
    } else {
      book.sha256 = input.sha256;
      book.size = input.size;
      book.format = input.format;
      book.docId = input.docId;
      book.title = input.title;
      book.filename = input.filename;
    }
    await this.persist();
    return book.bookId;
  }

  async putHighlight(bookId: string, highlight: HighlightRecord): Promise<void> {
    await this.put(bookId, "highlight", highlight.id, highlightToPayload(highlight), false);
  }

  async putNote(bookId: string, note: NoteRecord): Promise<void> {
    await this.put(bookId, "note", note.id, noteToPayload(note), false);
  }

  async putWord(bookId: string, word: WordRecord): Promise<void> {
    await this.put(bookId, "word", word.id, wordToPayload(word), false);
  }

  async putLookup(bookId: string, wordId: string, lookup: LookupRecord): Promise<void> {
    await this.put(bookId, "lookup", lookup.id, lookupToPayload(wordId, lookup), false);
  }

  async deleteRecord(bookId: string, kind: ClientKind, id: string): Promise<void> {
    const current = this.findRecord(bookId, kind, id);
    const payload = current?.payload ?? { extras: {} };
    await this.put(bookId, kind, id, payload, true);
  }

  /**
   * Highlight plus its note, one pending batch. The note's id is the
   * highlight's id. Kind keeps the two records apart.
   */
  async deleteHighlight(bookId: string, highlightId: string): Promise<void> {
    const highlight = this.findRecord(bookId, "highlight", highlightId);
    const note = this.findRecord(bookId, "note", highlightId);
    if (note) this.stage(bookId, "note", highlightId, note.payload, true);
    this.stage(bookId, "highlight", highlightId, highlight?.payload ?? { extras: {} }, true);
    await this.persist();
    this.armFlushSoon();
    this.emit();
  }

  /** Push after the page has settled for 2s. Background flushes immediately. */
  updatePosition(bookId: string, locator: Locator): void {
    this.positionWait = { bookId, locator };
    this.positionTimer?.cancel();
    this.positionTimer = this.deps.clock.setTimeout(() => {
      this.positionTimer = null;
      return this.flushPositionNow();
    }, POSITION_SETTLE_MS);
    this.emit();
  }

  async openBook(bookId: string, here?: ReadingPlace): Promise<ResumeOffer | null> {
    const positions = this.state.positions.filter((position) => position.bookId === bookId && !position.deleted);
    if (positions.length === 0) {
      this.opened.delete(bookId);
      return null;
    }
    const best = positions.reduce((left, right) => (left.seq >= right.seq ? left : right));
    const deviceId = typeof best.payload.deviceId === "string" ? best.payload.deviceId : best.deviceId;
    const deviceName = await this.deviceName(deviceId);
    const locator = locatorOf(best.payload);
    if (!locator) return null;
    const offer = this.resumeOffer(bookId, locator, deviceId, deviceName, best.seq, here);
    this.opened.set(bookId, offer);
    return offer;
  }


  listedBooks(): BookListItem[] {
    if (this.listed.length > 0) return clone(this.listed);
    return this.state.books.map((book) => localBookToListItem(book));
  }

  latestPosition(bookId: string): StoredPosition | null {
    const positions = this.state.positions.filter((position) => position.bookId === bookId && !position.deleted);
    if (positions.length === 0) return null;
    return positions.reduce((left, right) => (left.seq >= right.seq ? left : right));
  }

  async refreshLibrary(): Promise<BookListItem[]> {
    if (!this.isPaired()) return this.listedBooks();
    const response = await this.deps.transport.books();
    this.listed = response.books;
    for (const item of response.books) this.upsertListedBook(item);
    await this.persist();
    this.emit();
    return this.listedBooks();
  }

  async downloadBookBytes(bookId: string): Promise<{ sha256: string; bytes: Uint8Array; format: string; size: number }> {
    if (this.listed.length === 0 && this.isPaired()) {
      try {
        await this.refreshLibrary();
      } catch {
        // Fall through and try the cached list / local book.
      }
    }
    const listed = this.listed.find((item) => item.bookId === bookId);
    const local = this.state.books.find((item) => item.bookId === bookId);
    const book = listed ?? (local ? localBookToListItem(local) : null);
    if (!book) throw new SyncApiError(404, "not_found", `no book ${bookId}`);
    const bytes = await downloadBookBlob(this.deps.transport, book);
    const chosen = chooseBlobFile(book);
    return {
      sha256: chosen?.sha256 ?? book.sha256,
      bytes,
      format: book.format,
      size: bytes.byteLength,
    };
  }

  /**
   * Drop credentials and remote sync state. Local highlight shelves in
   * AsyncStorage are left alone. The engine stays started so a new pair works.
   */
  async unpair(): Promise<void> {
    this.pullTimer?.cancel();
    this.backoffTimer?.cancel();
    this.flushTimer?.cancel();
    this.positionTimer?.cancel();
    this.errorTimer?.cancel();
    this.pullTimer = null;
    this.backoffTimer = null;
    this.flushTimer = null;
    this.positionTimer = null;
    this.errorTimer = null;
    this.positionWait = null;
    this.flushing = null;
    this.listed = [];
    this.opened.clear();
    this.pausedBytes.clear();
    this.attempts = 0;
    this.flight = 0;
    this.deps.session.baseUrl = null;
    this.deps.session.credential = null;
    await this.deps.credentials.delete(CREDENTIAL_KEY);
    this.state = emptyPersisted();
    await this.persist();
    this.emit();
  }

  exportState(): PersistedSync {
    return clone(this.state);
  }

  /** Idempotent page apply. Saving the cursor is the caller's `pull`. */
  applyPulledPage(page: PullResponse): void {
    if (this.state.serverId && page.serverId !== this.state.serverId) {
      this.resetForNewServer(page.serverId);
      return;
    }
    if (!this.state.serverId) this.state.serverId = page.serverId;
    for (const envelope of page.changes) this.applyEnvelope(envelope);
    this.state.cursor = page.cursor;
    this.state.lastSyncedAt = this.deps.clock.iso();
  }

  async pull(): Promise<void> {
    if (!this.deps.session.credential || !this.deps.session.baseUrl) return;
    this.flight += 1;
    this.emit();
    try {
      let since = this.state.cursor;
      const limit = this.deps.pullLimit ?? 1000;
      for (;;) {
        const page = await this.deps.transport.pull(since, limit);
        if (this.state.serverId && page.serverId !== this.state.serverId) {
          this.resetForNewServer(page.serverId);
          await this.persist();
          this.flight -= 1;
          if (!this.flushing) await this.flush();
          return;
        }
        this.applyPulledPage(page);
        since = this.state.cursor;
        await this.persist();
        if (!page.hasMore) break;
      }
      this.clearFailure();
      await this.refreshLibraryQuiet();
    } catch (error) {
      this.noteFailure(error);
    } finally {
      if (this.flight > 0) this.flight -= 1;
      this.emit();
    }
  }

  async flush(): Promise<void> {
    if (this.flushing) {
      await this.flushing;
      if ((this.state.pending?.changes.length ?? 0) > 0 && !this.state.inflight) return this.flush();
      return;
    }
    this.flushing = this.flushOnce().finally(() => {
      this.flushing = null;
    });
    await this.flushing;
  }

  private async flushOnce(depth = 0): Promise<void> {
    if (!this.state.inflight && this.state.pending && this.state.pending.changes.length > 0) {
      this.state.inflight = this.state.pending;
      this.state.pending = null;
      await this.persist();
    }
    const batch = this.state.inflight;
    if (!batch || batch.changes.length === 0) return;
    if (!this.deps.session.credential || !this.deps.session.baseUrl) return;
    try {
      await this.registerBooks(batch);
      this.flight += 1;
      this.emit();
      const response = await this.deps.transport.push({
        batchId: batch.batchId,
        changes: batch.changes.map(toChangeInput),
      });
      this.flight -= 1;
      this.applyPush(batch, response);
      this.state.inflight = null;
      this.attempts = 0;
      this.clearFailure();
      await this.persist();
      this.emit();
      await this.pull();
      if (depth < 4 && (this.state.pending?.changes.length ?? 0) > 0) await this.flushOnce(depth + 1);
    } catch (error) {
      if (this.flight > 0) this.flight -= 1;
      if (error instanceof SyncApiError && error.code === "use_register" && error.status === 400) {
        if (this.state.inflight) {
          this.state.pending = this.state.inflight;
          this.state.inflight = null;
        }
        await this.persist();
        this.emit();
        return;
      }
      if (error instanceof SyncApiError && error.code === "change_id_reused" && error.status === 422 && this.state.inflight) {
        this.state.inflight = {
          batchId: newId(),
          changes: this.state.inflight.changes.map((change) => ({ ...change, changeId: newId() })),
        };
        await this.persist();
        this.emit();
        return;
      }
      this.noteFailure(error);
      if (isRetryable(error)) this.scheduleBackoff();
      await this.persist();
      this.emit();
    }
  }

  private applyPush(batch: OutboxBatch, response: PushResponse): void {
    const retry: OutboxChange[] = [];
    for (const result of response.results) {
      const change = batch.changes.find((item) => item.changeId === result.changeId);
      if (!change) continue;
      const record = this.findRecord(change.bookId, change.kind, change.id);
      if (result.status === "applied" || result.status === "noop") {
        if (record && result.version !== undefined) {
          record.serverVersion = result.version;
          if (record.generation === change.generation) record.dirty = false;
          else this.retargetPending(record);
        }
        if (change.kind === "position" && record && result.seq !== undefined) {
          this.upsertPosition({
            bookId: record.bookId,
            id: record.id,
            deviceId: this.deps.device.deviceId,
            seq: result.seq,
            version: result.version ?? record.serverVersion,
            deleted: record.deleted,
            payload: clone(record.payload),
          });
        }
      } else if (result.status === "conflict") {
        if (record) record.heldGeneration = record.generation;
      } else if (result.status === "rejected" && result.error?.code === "unknown_book") {
        const book = this.state.books.find((item) => item.bookId === change.bookId);
        if (book) book.registeredForServerId = null;
        retry.push({ ...change, changeId: newId() });
      } else if (result.status === "rejected" && result.error?.code === "change_id_reused") {
        retry.push({ ...change, changeId: newId() });
      } else if (
        record &&
        (result.error?.code === "bad_base" || result.error?.code === "not_owner" || result.error?.code === "bad_request")
      ) {
        record.heldGeneration = record.generation;
      } else if (record) {
        record.heldGeneration = record.generation;
      }
    }
    if (retry.length > 0) {
      if (!this.state.pending) this.state.pending = { batchId: newId(), changes: [] };
      for (const change of retry) this.coalesce(this.state.pending, change);
    }
  }

  private async registerBooks(batch: OutboxBatch): Promise<void> {
    const bookIds = [...new Set(batch.changes.map((change) => change.bookId))];
    for (const bookId of bookIds) {
      const book = this.state.books.find((item) => item.bookId === bookId);
      if (!book) throw new SyncApiError(400, "unknown_book", `missing local book ${bookId}`);
      if (book.registeredForServerId === this.state.serverId) continue;
      const response = await this.deps.transport.registerBook({
        sha256: book.sha256,
        size: book.size,
        format: book.format,
        docId: book.docId,
        title: book.title,
        filename: book.filename,
      });
      if (response.bookId !== book.bookId) this.adoptBookId(book.bookId, response.bookId);
      const current = this.state.books.find((item) => item.bookId === response.bookId);
      if (current) current.registeredForServerId = this.state.serverId;
      await this.persist();
    }
  }

  private adoptBookId(from: string, to: string): void {
    const book = this.state.books.find((item) => item.bookId === from);
    if (book) book.bookId = to;
    for (const record of this.state.records) if (record.bookId === from) record.bookId = to;
    for (const position of this.state.positions) if (position.bookId === from) position.bookId = to;
    for (const batch of [this.state.inflight, this.state.pending]) {
      if (!batch) continue;
      for (const change of batch.changes) if (change.bookId === from) change.bookId = to;
    }
  }

  private async put(bookId: string, kind: ClientKind, id: string, payload: JsonObject, deleted: boolean): Promise<void> {
    this.stage(bookId, kind, id, payload, deleted);
    await this.persist();
    this.armFlushSoon();
    this.emit();
  }

  private stage(bookId: string, kind: ClientKind, id: string, payload: JsonObject, deleted: boolean): void {
    let record = this.findRecord(bookId, kind, id);
    if (!record) {
      record = {
        bookId,
        kind,
        id,
        serverVersion: 0,
        deleted,
        payload: clone(payload),
        dirty: true,
        generation: 1,
        heldGeneration: null,
      };
      this.state.records.push(record);
    } else {
      record.payload = clone(payload);
      record.deleted = deleted;
      record.generation += 1;
      record.dirty = true;
      record.heldGeneration = null;
    }
    this.enqueue(record);
  }

  private enqueue(record: LocalRecord): void {
    if (record.heldGeneration !== null && record.heldGeneration === record.generation) return;
    if (!this.state.pending) this.state.pending = { batchId: newId(), changes: [] };
    const existing = this.state.pending.changes.find((change) => sameKey(change, record));
    if (existing) {
      existing.deleted = record.deleted;
      existing.payload = clone(record.payload);
      existing.clientTime = this.deps.clock.iso();
      existing.generation = record.generation;
      existing.baseVersion = record.serverVersion;
      return;
    }
    // A change already on the wire keeps its body. This one waits in the next batch.
    this.state.pending.changes.push(this.changeFrom(record));
  }

  private changeFrom(record: LocalRecord): OutboxChange {
    return {
      changeId: newId(),
      bookId: record.bookId,
      kind: record.kind,
      id: record.id,
      baseVersion: record.serverVersion,
      deleted: record.deleted,
      clientTime: this.deps.clock.iso(),
      payload: clone(record.payload),
      generation: record.generation,
    };
  }

  private coalesce(batch: OutboxBatch, change: OutboxChange): void {
    const existing = batch.changes.find((item) => sameKey(item, change));
    if (existing) {
      existing.deleted = change.deleted;
      existing.payload = clone(change.payload);
      existing.clientTime = change.clientTime;
      existing.generation = change.generation;
      existing.baseVersion = change.baseVersion;
      return;
    }
    batch.changes.push(change);
  }

  private retargetPending(record: LocalRecord): void {
    const pending = this.state.pending?.changes.find((change) => sameKey(change, record));
    if (pending) pending.baseVersion = record.serverVersion;
  }

  private applyEnvelope(envelope: Envelope): void {
    if (envelope.kind === "book") {
      this.applyBookEnvelope(envelope);
      return;
    }
    if (envelope.conflict) this.upsertConflict(envelope.conflict);
    else this.state.conflicts = this.state.conflicts.filter((conflict) => !sameKey(conflict, envelope));

    if (envelope.kind === "position") {
      const deviceId = typeof envelope.payload.deviceId === "string" ? envelope.payload.deviceId : envelope.deviceId;
      this.upsertPosition({
        bookId: envelope.bookId,
        id: envelope.id,
        deviceId,
        seq: envelope.seq,
        version: envelope.version,
        deleted: envelope.deleted,
        payload: clone(envelope.payload),
      });
    }

    const kind = envelope.kind;
    const local = this.findRecord(envelope.bookId, kind, envelope.id);
    if (local?.dirty) return;
    if (!local) {
      this.state.records.push({
        bookId: envelope.bookId,
        kind,
        id: envelope.id,
        serverVersion: envelope.version,
        deleted: envelope.deleted,
        payload: clone(envelope.payload),
        dirty: false,
        generation: 0,
        heldGeneration: null,
      });
      return;
    }
    local.serverVersion = envelope.version;
    local.deleted = envelope.deleted;
    local.payload = clone(envelope.payload);
    local.dirty = false;
    local.heldGeneration = null;
  }

  private applyBookEnvelope(envelope: Envelope): void {
    const payload = envelope.payload;
    const sha = typeof payload.currentSha256 === "string" ? payload.currentSha256 : "";
    let book = this.state.books.find((item) => item.bookId === envelope.bookId);
    if (!book) {
      book = {
        bookId: envelope.bookId,
        sha256: sha,
        size: 0,
        format: typeof payload.format === "string" ? payload.format : "",
        docId: typeof payload.docId === "string" ? payload.docId : undefined,
        title: typeof payload.title === "string" ? payload.title : "",
        filename: typeof payload.filename === "string" ? payload.filename : "",
        registeredForServerId: this.state.serverId,
      };
      this.state.books.push(book);
      return;
    }
    if (sha) book.sha256 = sha;
    if (typeof payload.title === "string") book.title = payload.title;
    if (typeof payload.filename === "string") book.filename = payload.filename;
    if (typeof payload.format === "string") book.format = payload.format;
  }

  private upsertConflict(conflict: OpenConflict): void {
    this.state.conflicts = this.state.conflicts.filter((item) => item.conflictId !== conflict.conflictId && !sameKey(item, conflict));
    this.state.conflicts.push(clone(conflict));
  }

  private upsertPosition(position: StoredPosition): void {
    const index = this.state.positions.findIndex((item) => item.bookId === position.bookId && item.id === position.id);
    if (index < 0) {
      this.state.positions.push(position);
      return;
    }
    if (this.state.positions[index].seq > position.seq) return;
    this.state.positions[index] = position;
  }

  private resetForNewServer(serverId: string): void {
    this.state.serverId = serverId;
    this.state.cursor = 0;
    this.state.conflicts = [];
    this.state.devices = [];
    this.state.positions = [];
    this.state.inflight = null;
    this.state.pending = null;
    this.state.lastSyncedAt = null;
    this.clearFailure();
    for (const book of this.state.books) book.registeredForServerId = null;
    for (const record of this.state.records) {
      record.serverVersion = 0;
      record.dirty = true;
      record.heldGeneration = null;
      record.generation += 1;
      this.enqueue(record);
    }
  }

  private async flushPositionNow(): Promise<void> {
    const waiting = this.positionWait;
    this.positionWait = null;
    this.positionTimer?.cancel();
    this.positionTimer = null;
    if (!waiting) return;
    const id = positionId(waiting.bookId, this.deps.device.deviceId);
    const payload = positionToPayload(waiting.bookId, this.deps.device.deviceId, waiting.locator);
    await this.put(waiting.bookId, "position", id, payload as unknown as JsonObject, false);
    await this.flush();
  }

  private resumeOffer(
    bookId: string,
    locator: Locator,
    deviceId: string,
    deviceName: string,
    seq: number,
    here?: ReadingPlace,
  ): ResumeOffer {
    const own = deviceId === this.deps.device.deviceId;
    let near = false;
    let action = "Back";
    if (locator.format === "pdf") {
      action = `Back to p. ${locator.page}`;
      if (here?.page !== undefined && Math.abs(here.page - locator.page) <= 1) near = true;
    } else {
      const chapter = epubChapterKey(locator.cfi);
      action = `Back to ${chapter}`;
      if (here?.chapterKey !== undefined && here.chapterKey === chapter) near = true;
    }
    const lead = `Opened where you left off on ${deviceName}`;
    const show = !own && !near;
    return {
      bookId,
      locator,
      deviceId,
      deviceName,
      seq,
      toast: show ? `${lead} · ${action}` : null,
      toastLead: show ? lead : null,
      toastAction: show ? action : null,
      toastDurationMs: POSITION_TOAST_MS,
    };
  }

  private async deviceName(deviceId: string): Promise<string> {
    const cached = this.state.devices.find((device) => device.deviceId === deviceId);
    if (cached) return cached.name;
    const list = await this.deps.transport.devices();
    this.state.devices = list.devices;
    await this.persist();
    return this.state.devices.find((device) => device.deviceId === deviceId)?.name ?? "another device";
  }

  private rememberDevice(device: DeviceInfo): void {
    this.state.devices = this.state.devices.filter((item) => item.deviceId !== device.deviceId);
    this.state.devices.push(device);
  }

  private clearPaused(bookId: string): void {
    this.pausedBytes.delete(bookId);
    this.state.pausedBookIds = this.state.pausedBookIds.filter((id) => id !== bookId);
    if (this.state.pausedBookIds.length === 0) this.state.storageFull = false;
  }


  private async refreshLibraryQuiet(): Promise<void> {
    try {
      await this.refreshLibrary();
    } catch {
      // A book-list failure must not fail an otherwise successful pull.
    }
  }

  private upsertListedBook(item: BookListItem): void {
    let book = this.state.books.find((entry) => entry.bookId === item.bookId);
    if (!book) {
      book = {
        bookId: item.bookId,
        sha256: item.sha256,
        size: item.size,
        format: item.format,
        docId: item.docId,
        title: item.title,
        filename: item.filename,
        registeredForServerId: this.state.serverId,
      };
      this.state.books.push(book);
      return;
    }
    if (item.sha256) book.sha256 = item.sha256;
    if (item.size) book.size = item.size;
    if (item.format) book.format = item.format;
    if (item.docId !== undefined) book.docId = item.docId;
    if (item.title) book.title = item.title;
    if (item.filename) book.filename = item.filename;
    book.registeredForServerId = this.state.serverId;
  }

  private findRecord(bookId: string, kind: ClientKind, id: string): LocalRecord | undefined {
    return this.state.records.find((record) => record.bookId === bookId && record.kind === kind && record.id === id);
  }

  private noteFailure(error: unknown): void {
    if (!isRetryable(error)) {
      this.emit();
      return;
    }
    if (this.state.failureStartedAt === null) {
      this.state.failureStartedAt = this.deps.clock.now();
      this.armErrorThreshold();
    }
  }

  private clearFailure(): void {
    this.state.failureStartedAt = null;
    this.attempts = 0;
    this.backoffTimer?.cancel();
    this.errorTimer?.cancel();
    this.errorTimer = null;
  }

  private armErrorThreshold(): void {
    this.errorTimer?.cancel();
    if (this.state.failureStartedAt === null) return;
    const due = this.state.failureStartedAt + ERROR_AFTER_MS - this.deps.clock.now();
    this.errorTimer = this.deps.clock.setTimeout(() => this.emit(), Math.max(0, due));
  }

  private scheduleBackoff(): void {
    this.backoffTimer?.cancel();
    const delay = Math.min(BACKOFF_CAP_MS, BACKOFF_START_MS * 2 ** this.attempts);
    this.attempts += 1;
    this.backoffTimer = this.deps.clock.setTimeout(() => this.flush(), delay);
  }

  private armPull(): void {
    this.pullTimer?.cancel();
    if (!this.active) return;
    this.pullTimer = this.deps.clock.setTimeout(() => this.pull().finally(() => this.armPull()), PULL_INTERVAL_MS);
  }

  private armFlushSoon(): void {
    if (this.flushTimer) return;
    this.flushTimer = this.deps.clock.setTimeout(() => {
      this.flushTimer = null;
      return this.flush();
    }, 0);
  }

  private async persist(): Promise<void> {
    await this.deps.storage.save(this.state);
  }

  private emit(): void {
    const status = this.status();
    for (const listener of this.listeners) listener(status);
  }
}

function isStorageFull(error: unknown): boolean {
  return (
    error instanceof SyncApiError &&
    error.status === 507 &&
    (error.code === "disk_full" || error.code === "quota_exceeded")
  );
}

function toChangeInput(change: OutboxChange): ChangeInput {
  return {
    changeId: change.changeId,
    bookId: change.bookId,
    kind: change.kind,
    id: change.id,
    baseVersion: change.baseVersion,
    deleted: change.deleted,
    clientTime: change.clientTime,
    payload: change.payload,
  };
}

function localBookToListItem(book: { bookId: string; sha256: string; size: number; format: string; docId?: string; title: string; filename: string }): BookListItem {
  return {
    bookId: book.bookId,
    title: book.title,
    filename: book.filename,
    format: book.format,
    docId: book.docId,
    sha256: book.sha256,
    size: book.size,
    hasBlob: false,
    files: book.sha256 ? [{ sha256: book.sha256, size: book.size, hasBlob: false }] : [],
    version: 0,
    seq: 0,
  };
}
