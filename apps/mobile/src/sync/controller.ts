import type { BookIdentity } from "../contract/types";
import type { BookShelf } from "../reader/shelf";
import type { SyncStorage } from "./storage";
import { createAsyncSyncStorage } from "./asyncStorage";
import { createSecureCredentialStore, type CredentialStore } from "./credentials";
import { systemClock } from "./clock";
import { SyncEngine, type EngineSession, type SyncDevice } from "./engine";
import { HttpTransport } from "./transport";
import type { SyncStatus } from "./status";
import { mergeSyncRecords } from "./mergeShelf";

export const unpairedStatus: SyncStatus = {
  state: "unpaired",
  pendingCount: 0,
  conflictCount: 0,
  pausedBookIds: [],
  lastSyncedAt: null,
};

export const DEVICE_ID_KEY = "readersync.deviceId";

export function presentStatus(engine: SyncEngine): SyncStatus {
  if (!engine.isPaired()) return { ...unpairedStatus, lastSyncedAt: engine.status().lastSyncedAt };
  return engine.status();
}

export function bookIdOf(identity: BookIdentity): string {
  return identity.fingerprint;
}

export function sha256OfFingerprint(fingerprint: string): string {
  return fingerprint.startsWith("sha256:") ? fingerprint.slice("sha256:".length) : fingerprint;
}

export interface CreateLiveEngineOptions {
  storage?: SyncStorage;
  credentials?: CredentialStore;
  device: SyncDevice;
  fetchImpl?: typeof fetch;
}

export function createLiveEngine(options: CreateLiveEngineOptions): { engine: SyncEngine; session: EngineSession } {
  const session: EngineSession = { baseUrl: null, credential: null };
  const transport = new HttpTransport({
    baseUrl: () => session.baseUrl,
    credential: () => session.credential,
    fetchImpl: options.fetchImpl,
  });
  const engine = new SyncEngine({
    transport,
    storage: options.storage ?? createAsyncSyncStorage(),
    credentials: options.credentials ?? createSecureCredentialStore(),
    clock: systemClock(),
    device: options.device,
    session,
  });
  return { engine, session };
}

export async function loadOrCreateDeviceId(credentials: CredentialStore): Promise<string> {
  const existing = await credentials.get(DEVICE_ID_KEY);
  if (existing && existing.length > 0) return existing;
  const minted = `dev_${globalThis.crypto.randomUUID().replace(/-/g, "")}`;
  await credentials.set(DEVICE_ID_KEY, minted);
  return minted;
}

export function mergeBookShelf(shelf: BookShelf, engine: SyncEngine, bookId: string): BookShelf {
  return mergeSyncRecords(shelf, engine.recordsFor(bookId));
}

