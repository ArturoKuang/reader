import type { JsonValue } from "../contract/types";
import type { ClientKind, DeviceInfo, JsonObject, OpenConflict } from "./wire";

export interface LocalBook {
  bookId: string;
  sha256: string;
  size: number;
  format: string;
  docId?: string;
  title: string;
  filename: string;
  /** Server id this book was last registered with. */
  registeredForServerId: string | null;
}

export interface LocalRecord {
  bookId: string;
  kind: ClientKind;
  id: string;
  serverVersion: number;
  deleted: boolean;
  payload: JsonObject;
  dirty: boolean;
  generation: number;
  /**
   * Generation that the server already answered with a conflict.
   * That generation is not pushed again. A newer local edit clears it.
   */
  heldGeneration: number | null;
}

export interface OutboxChange {
  changeId: string;
  bookId: string;
  kind: ClientKind;
  id: string;
  baseVersion: number;
  deleted: boolean;
  clientTime: string;
  payload: JsonObject;
  generation: number;
}

export interface OutboxBatch {
  batchId: string;
  changes: OutboxChange[];
}

export interface StoredPosition {
  bookId: string;
  id: string;
  deviceId: string;
  seq: number;
  version: number;
  deleted: boolean;
  payload: JsonObject;
}

export interface PersistedSync {
  serverId: string | null;
  cursor: number;
  /** QR `url`, trailing slash already removed. */
  baseUrl: string | null;
  storageFull: boolean;
  pausedBookIds: string[];
  books: LocalBook[];
  records: LocalRecord[];
  positions: StoredPosition[];
  conflicts: OpenConflict[];
  devices: DeviceInfo[];
  inflight: OutboxBatch | null;
  pending: OutboxBatch | null;
  lastSyncedAt: string | null;
  /** Epoch ms. Not an ISO string, so a fake clock can compare it. */
  failureStartedAt: number | null;
}

export function emptyPersisted(): PersistedSync {
  return {
    serverId: null,
    cursor: 0,
    baseUrl: null,
    storageFull: false,
    pausedBookIds: [],
    books: [],
    records: [],
    positions: [],
    conflicts: [],
    devices: [],
    inflight: null,
    pending: null,
    lastSyncedAt: null,
    failureStartedAt: null,
  };
}

export interface SyncStorage {
  load(): Promise<PersistedSync | null>;
  save(state: PersistedSync): Promise<void>;
}

/** Process-local store. Tests share one instance across an "app kill". */
export class MemorySyncStorage implements SyncStorage {
  snapshot: PersistedSync | null = null;
  saves = 0;

  async load(): Promise<PersistedSync | null> {
    return this.snapshot ? structuredClone(this.snapshot) : null;
  }

  async save(state: PersistedSync): Promise<void> {
    this.snapshot = structuredClone(state);
    this.saves += 1;
  }
}

export type JsonRecord = { [key: string]: JsonValue };
