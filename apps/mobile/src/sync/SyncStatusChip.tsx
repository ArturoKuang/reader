import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { tokens } from "../ui/tokens";
import type { SyncStatus } from "./status";
import { ConflictCard } from "./ConflictCard";
import type { OpenConflict } from "./wire";

const chip = tokens.syncStatus;

export function SyncStatusChip({ status, onPress }: { status: SyncStatus; onPress?: () => void }) {
  const tone = chip[status.state];
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`sync ${status.state}`}
      testID="sync-status-chip"
      onPress={onPress}
    >
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: tone.dot }]} />
        <Text>{tone.label}</Text>
      </View>
    </Pressable>
  );
}

/**
 * Chip plus the pairing / sync sheet, the storage-full actions, and
 * the read-only conflict cards. Mounted from the library header.
 */
export function SyncChrome({
  status,
  conflicts,
  pairingError,
  onCheckAgain,
  onRetry,
  onSyncNow,
  onPair,
}: {
  status: SyncStatus;
  conflicts: readonly OpenConflict[];
  pairingError?: string | null;
  onCheckAgain?: () => void;
  onRetry?: () => void;
  onSyncNow?: () => void;
  onPair?: (url: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const unpaired = status.state === "unpaired";
  return (
    <View>
      <SyncStatusChip
        status={status}
        onPress={() => {
          if (status.state === "error") onRetry?.();
          setOpen((value) => !value);
        }}
      />
      {open ? (
        <View testID="sync-sheet" accessibilityLabel="sync sheet" style={styles.sheet}>
          <Text style={styles.heading}>{unpaired ? "Pair" : "Sync"}</Text>
          {unpaired ? (
            <View style={styles.block}>
              <Text>Paste a readersync://pair?v=2 link to connect this phone.</Text>
              <TextInput
                testID="pair-url-input"
                accessibilityLabel="Pairing URL"
                autoCapitalize="none"
                autoCorrect={false}
                onChangeText={setUrl}
                placeholder="readersync://pair?v=2&..."
                style={styles.input}
                value={url}
              />
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="Pair"
                testID="pair-submit"
                onPress={() => onPair?.(url.trim())}
                style={styles.button}
              >
                <Text style={styles.buttonLabel}>Pair</Text>
              </Pressable>
              {pairingError ? <Text style={styles.error}>{pairingError}</Text> : null}
            </View>
          ) : (
            <View style={styles.block}>
              {status.lastSyncedAt ? <Text>Last synced {status.lastSyncedAt}</Text> : null}
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="Sync now"
                testID="sync-now"
                onPress={() => onSyncNow?.()}
                style={styles.button}
              >
                <Text style={styles.buttonLabel}>Sync now</Text>
              </Pressable>
            </View>
          )}
          {status.state === "storageFull" ? (
            <View accessibilityLabel="storage full sheet" style={styles.block}>
              <Text>{chip.storageFull.detail}</Text>
              <Text>{status.pausedBookIds.length} books waiting</Text>
              {status.pausedBookIds.map((bookId) => (
                <Text key={bookId}>
                  {bookId} · {chip.storageFull.badge}
                </Text>
              ))}
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={chip.storageFull.action}
                onPress={() => onCheckAgain?.()}
              >
                <Text>{chip.storageFull.action}</Text>
              </Pressable>
            </View>
          ) : null}
          {status.state === "conflict"
            ? conflicts.map((conflict) => <ConflictCard key={conflict.conflictId} conflict={conflict} />)
            : null}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", gap: 8 },
  dot: { width: 8, height: 8, borderRadius: 8 },
  sheet: {
    marginTop: 8,
    padding: 12,
    borderRadius: 12,
    backgroundColor: tokens.paper,
    gap: 8,
    maxWidth: 320,
  },
  heading: { fontSize: 17, fontWeight: "600", color: tokens.ink },
  block: { gap: 8 },
  input: {
    minHeight: 44,
    borderWidth: 1,
    borderColor: tokens.line,
    borderRadius: 12,
    paddingHorizontal: 12,
    color: tokens.ink,
  },
  button: {
    minHeight: 44,
    borderRadius: 12,
    backgroundColor: tokens.ink,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 16,
  },
  buttonLabel: { color: tokens.paper, fontWeight: "600" },
  error: { color: "#EB5757" },
});
