import AsyncStorage from "@react-native-async-storage/async-storage";
import type { PersistedSync, SyncStorage } from "./storage";

const KEY = "readersync.state";

export interface KeyValueStore {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
}

/**
 * The outbox uses the same AsyncStorage the reader shelf already uses.
 * One key holds the engine snapshot, including a batch written before send.
 */
export function createAsyncSyncStorage(store: KeyValueStore = AsyncStorage): SyncStorage {
  return {
    async load() {
      const raw = await store.getItem(KEY);
      if (!raw) return null;
      return JSON.parse(raw) as PersistedSync;
    },
    async save(state) {
      await store.setItem(KEY, JSON.stringify(state));
    },
  };
}
