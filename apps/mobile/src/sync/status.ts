/**
 * Chip states from the phone mockup. The value is derived; the screen
 * maps labels and colors onto it later.
 *
 * Error replaces Offline only after about 30 seconds of continuous failed
 * retries. A short drop stays Offline. Conflicts stay a separate count
 * (and a read-only card). They become the chip state when the phone is
 * otherwise caught up.
 */
export const SYNC_STATES = ["synced", "syncing", "offline", "conflict", "error", "storageFull"] as const;

export type SyncChipState = (typeof SYNC_STATES)[number] | "unpaired";

export interface SyncStatus {
  state: SyncChipState;
  pendingCount: number;
  conflictCount: number;
  /** Book ids whose blob upload is paused because the Mac mini is full. */
  pausedBookIds: string[];
  /** ISO-8601 of the last successful push or pull. Null before the first. */
  lastSyncedAt: string | null;
}

/** How long retries must keep failing before the chip leaves Offline. */
export const ERROR_AFTER_MS = 30_000;

export const PULL_INTERVAL_MS = 30_000;
export const POSITION_SETTLE_MS = 2_000;
export const POSITION_TOAST_MS = 5_000;

export interface StatusInput {
  pendingCount: number;
  conflictCount: number;
  lastSyncedAt: string | null;
  /** A push or pull is on the wire. */
  inFlight: boolean;
  /** `clock.now()` when the current failure streak began, or null. */
  failureStartedAt: number | null;
  /** HTTP 507 disk_full or quota_exceeded. Not a network failure. */
  storageFull: boolean;
  pausedBookIds: string[];
  now: number;
}

export function deriveSyncStatus(input: StatusInput): SyncStatus {
  const failingFor =
    input.failureStartedAt === null ? null : Math.max(0, input.now - input.failureStartedAt);
  let state: SyncChipState;
  if (failingFor !== null && failingFor >= ERROR_AFTER_MS) {
    state = "error";
  } else if (input.storageFull) {
    state = "storageFull";
  } else if (input.conflictCount > 0) {
    state = "conflict";
  } else if (failingFor !== null) {
    state = "offline";
  } else if (input.inFlight || input.pendingCount > 0) {
    state = "syncing";
  } else {
    state = "synced";
  }
  return {
    state,
    pendingCount: input.pendingCount,
    conflictCount: input.conflictCount,
    pausedBookIds: input.pausedBookIds,
    lastSyncedAt: input.lastSyncedAt,
  };
}
