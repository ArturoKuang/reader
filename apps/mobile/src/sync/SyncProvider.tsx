import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { AppState, Linking, Platform } from "react-native";
import type { HighlightRecord, NoteRecord } from "../contract/types";
import type { BookShelf } from "../reader/shelf";
import { createSecureCredentialStore } from "./credentials";
import {
  createLiveEngine,
  loadOrCreateDeviceId,
  mergeBookShelf,
  presentStatus,
  unpairedStatus,
} from "./controller";
import type { ReadingPlace, ResumeOffer, SyncEngine } from "./engine";
import type { LocalRecord, StoredPosition } from "./storage";
import type { SyncStatus } from "./status";
import type { BookListItem, ClientKind, Locator, OpenConflict, RegisterBookRequest } from "./wire";

export interface SyncController {
  status: SyncStatus;
  conflicts: OpenConflict[];
  pairingError: string | null;
  isPaired: boolean;
  pair(url: string): Promise<void>;
  syncNow(): Promise<void>;
  recheckStorage(): Promise<void>;
  retryNow(): Promise<void>;
  ensureBook(input: RegisterBookRequest): Promise<string>;
  putHighlight(bookId: string, highlight: HighlightRecord): Promise<void>;
  putNote(bookId: string, note: NoteRecord): Promise<void>;
  deleteHighlight(bookId: string, highlightId: string): Promise<void>;
  deleteNote(bookId: string, noteId: string): Promise<void>;
  mergeShelf(shelf: BookShelf, bookId: string): BookShelf;
  books: BookListItem[];
  unpair(): Promise<void>;
  refreshLibrary(): Promise<void>;
  downloadBook(bookId: string): Promise<{ sha256: string; bytes: Uint8Array; format: string; size: number }>;
  openBook(bookId: string, here?: ReadingPlace): Promise<ResumeOffer | null>;
  updatePosition(bookId: string, locator: Locator): void;
  recordsFor(bookId: string): LocalRecord[];
  latestPosition(bookId: string): StoredPosition | null;
  conflictsFor(bookId: string, kind: ClientKind, id: string): OpenConflict | null;
}

const SyncContext = createContext<SyncController | null>(null);

export function useSync(): SyncController | null {
  return useContext(SyncContext);
}

export function SyncProvider({ children }: { children: ReactNode }) {
  const engineRef = useRef<SyncEngine | null>(null);
  const startedRef = useRef(false);
  const pendingUrlRef = useRef<string | null>(null);
  const [status, setStatus] = useState<SyncStatus>(unpairedStatus);
  const [conflicts, setConflicts] = useState<OpenConflict[]>([]);
  const [pairingError, setPairingError] = useState<string | null>(null);
  const [isPaired, setIsPaired] = useState(false);
  const [books, setBooks] = useState<BookListItem[]>([]);

  const refresh = useCallback(() => {
    const engine = engineRef.current;
    if (!engine) return;
    setStatus(presentStatus(engine));
    setConflicts(engine.openConflicts());
    setIsPaired(engine.isPaired());
    setBooks(engine.listedBooks());
  }, []);

  const runCycle = useCallback(async () => {
    const engine = engineRef.current;
    if (!engine?.isPaired()) {
      refresh();
      return;
    }
    await engine.recheckStorage();
    await engine.flush();
    await engine.pull();
    refresh();
  }, [refresh]);

  const pair = useCallback(
    async (url: string) => {
      const engine = engineRef.current;
      if (!engine || !startedRef.current) {
        pendingUrlRef.current = url;
        return;
      }
      try {
        setPairingError(null);
        await engine.pair(url);
        await runCycle();
      } catch (error) {
        setPairingError(error instanceof Error ? error.message : String(error));
        refresh();
      }
    },
    [refresh, runCycle],
  );

  const pairRef = useRef(pair);
  const refreshRef = useRef(refresh);
  useEffect(() => {
    pairRef.current = pair;
    refreshRef.current = refresh;
  }, [pair, refresh]);

  useEffect(() => {
    const credentials = createSecureCredentialStore();
    let cancelled = false;
    let unsubscribe: (() => void) | undefined;
    void (async () => {
      const deviceId = await loadOrCreateDeviceId(credentials);
      if (cancelled) return;
      const { engine } = createLiveEngine({
        credentials,
        device: {
          deviceId,
          name: "Reader phone",
          platform: Platform.OS,
          appVersion: "1.0.0",
        },
      });
      engineRef.current = engine;
      unsubscribe = engine.subscribe(() => {
        if (!cancelled) refreshRef.current();
      });
      try {
        await engine.start();
        if (cancelled) return;
        startedRef.current = true;
        refreshRef.current();
        const queued = pendingUrlRef.current;
        pendingUrlRef.current = null;
        if (queued) await pairRef.current(queued);
      } catch (error) {
        if (!cancelled) {
          setPairingError(error instanceof Error ? error.message : String(error));
          refreshRef.current();
        }
      }
    })();
    return () => {
      cancelled = true;
      startedRef.current = false;
      unsubscribe?.();
      engineRef.current?.stop();
    };
  }, []);

  useEffect(() => {
    let lastUrl: string | null = null;
    const takeUrl = (url: string | null | undefined) => {
      if (!url || !url.startsWith("readersync:")) return;
      if (url === lastUrl) return;
      lastUrl = url;
      void pairRef.current(url);
    };
    void Linking.getInitialURL().then(takeUrl);
    const subscription = Linking.addEventListener("url", (event) => takeUrl(event.url));
    return () => subscription.remove();
  }, []);

  useEffect(() => {
    const subscription = AppState.addEventListener("change", (state) => {
      const engine = engineRef.current;
      if (!engine || !startedRef.current) return;
      if (state === "active") {
        void engine.onForeground().then(() => refreshRef.current());
      } else if (state === "background") {
        void engine.onBackground();
      }
    });
    return () => subscription.remove();
  }, []);

  const value = useMemo<SyncController>(() => {
    const withEngine = async (action: (engine: SyncEngine) => Promise<void>) => {
      const engine = engineRef.current;
      if (!engine) return;
      await action(engine);
      refresh();
    };
    return {
      status,
      conflicts,
      pairingError,
      isPaired,
      pair,
      syncNow: () => runCycle(),
      recheckStorage: () =>
        withEngine(async (engine) => {
          await engine.recheckStorage();
        }),
      retryNow: () =>
        withEngine(async (engine) => {
          await engine.retryNow();
        }),
      ensureBook: async (input) => {
        const engine = engineRef.current;
        if (!engine) return `sha256:${input.sha256}`;
        const bookId = await engine.trackBook(input);
        refresh();
        return bookId;
      },
      putHighlight: (bookId, highlight) =>
        withEngine(async (engine) => {
          await engine.putHighlight(bookId, highlight);
        }),
      putNote: (bookId, note) =>
        withEngine(async (engine) => {
          await engine.putNote(bookId, note);
        }),
      deleteHighlight: (bookId, highlightId) =>
        withEngine(async (engine) => {
          await engine.deleteHighlight(bookId, highlightId);
        }),
      deleteNote: (bookId, noteId) =>
        withEngine(async (engine) => {
          await engine.deleteRecord(bookId, "note", noteId);
        }),
      mergeShelf: (shelf, bookId) => {
        const engine = engineRef.current;
        return engine ? mergeBookShelf(shelf, engine, bookId) : shelf;
      },
      books,
      unpair: () =>
        withEngine(async (engine) => {
          await engine.unpair();
        }),
      refreshLibrary: () =>
        withEngine(async (engine) => {
          await engine.refreshLibrary();
        }),
      downloadBook: async (bookId) => {
        const engine = engineRef.current;
        if (!engine) throw new Error("sync engine is not ready");
        const downloaded = await engine.downloadBookBytes(bookId);
        refresh();
        return downloaded;
      },
      openBook: async (bookId, here) => {
        const engine = engineRef.current;
        if (!engine) return null;
        return engine.openBook(bookId, here);
      },
      updatePosition: (bookId, locator) => {
        engineRef.current?.updatePosition(bookId, locator);
      },
      recordsFor: (bookId) => engineRef.current?.recordsFor(bookId) ?? [],
      latestPosition: (bookId) => engineRef.current?.latestPosition(bookId) ?? null,
      conflictsFor: (bookId, kind, id) => engineRef.current?.conflictsFor(bookId, kind, id) ?? null,
    };
  }, [books, conflicts, isPaired, pair, pairingError, refresh, runCycle, status]);

  return <SyncContext.Provider value={value}>{children}</SyncContext.Provider>;
}
