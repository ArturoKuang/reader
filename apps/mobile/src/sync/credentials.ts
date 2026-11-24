export interface CredentialStore {
  get(key: string): Promise<string | null>;
  set(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
}

export const CREDENTIAL_KEY = "readersync.credential";

export class MemoryCredentialStore implements CredentialStore {
  private values = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }

  async set(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.values.delete(key);
  }
}

/** expo-secure-store. The key stays alphanumeric plus `.`, `_`, and `-`. */
export function createSecureCredentialStore(): CredentialStore {
  return {
    async get(key) {
      const secure = await import("expo-secure-store");
      return secure.getItemAsync(key);
    },
    async set(key, value) {
      const secure = await import("expo-secure-store");
      await secure.setItemAsync(key, value);
    },
    async delete(key) {
      const secure = await import("expo-secure-store");
      await secure.deleteItemAsync(key);
    },
  };
}
