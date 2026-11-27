import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { tokens } from "../ui/tokens";
import type { SyncStatus } from "./status";
import { ConflictCard } from "./ConflictCard";
import type { OpenConflict } from "./wire";
import { PairingScan } from "../ui/PairingScan";

const chip = tokens.syncStatus;

export function SyncStatusChip({ status, onPress }: { status: SyncStatus; onPress?: () => void }) {
  const tone = chip[status.state];
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`sync ${status.state}`}
      testID="sync-status-chip"
      onPress={onPress}
      style={styles.chip}
    >
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: tone.dot }]} />
        <Text style={styles.chipLabel}>{tone.label}</Text>
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
  onUnpair,
  onOpenConflict,
}: {
  status: SyncStatus;
  conflicts: readonly OpenConflict[];
  pairingError?: string | null;
  onCheckAgain?: () => void;
  onRetry?: () => void;
  onSyncNow?: () => void;
  onPair?: (url: string) => void;
  onUnpair?: () => void;
  onOpenConflict?: (conflict: OpenConflict) => void;
}) {
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [scanning, setScanning] = useState(false);
  const unpaired = status.state === "unpaired";

  function toggleSheet() {
    if (status.state === "error") onRetry?.();
    if (status.state === "conflict" && onOpenConflict && conflicts[0]) {
      onOpenConflict(conflicts[0]);
      return;
    }
    setOpen((value) => !value);
  }

  return (
    <View>
      <SyncStatusChip status={status} onPress={toggleSheet} />
      {open ? (
        <View testID="sync-sheet" accessibilityLabel="sync sheet" style={styles.sheet}>
          <Text style={styles.heading}>{unpaired ? "Pair" : "Sync"}</Text>
          {unpaired ? (
            <View style={styles.block}>
              <Text style={styles.title}>Connect to your Mac</Text>
              <Text style={styles.copy}>
                In Reader on your Mac, open Settings, then Phone, and scan the code shown there.
              </Text>
              {scanning ? (
                <PairingScan
                  onCode={(value) => {
                    setScanning(false);
                    setUrl(value);
                    onPair?.(value);
                  }}
                  onCancel={() => setScanning(false)}
                />
              ) : (
                <Pressable
                  accessibilityRole="button"
                  accessibilityLabel="Scan code"
                  testID="pair-scan"
                  onPress={() => setScanning(true)}
                  style={styles.button}
                >
                  <Text style={styles.buttonLabel}>Scan code</Text>
                </Pressable>
              )}
              <Text style={styles.hint}>Your phone needs Tailscale turned on.</Text>
              <Text style={styles.copy}>Or paste a readersync://pair?v=2 link to connect this phone.</Text>
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
              <Pressable
                accessibilityRole="button"
                accessibilityLabel="Unpair"
                testID="unpair"
                onPress={() => onUnpair?.()}
                style={styles.buttonSecondary}
              >
                <Text style={styles.buttonLabelDark}>Unpair</Text>
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
  chip: {
    borderWidth: 1,
    borderColor: tokens.line,
    borderRadius: tokens.radius.chip,
    paddingHorizontal: 8,
    paddingVertical: 3,
    minHeight: 28,
    justifyContent: "center",
  },
  row: { flexDirection: "row", alignItems: "center", gap: 5 },
  dot: { width: 7, height: 7, borderRadius: 7 },
  chipLabel: { color: tokens.ink, fontSize: 11 },
  sheet: {
    marginTop: 8,
    padding: 12,
    borderRadius: tokens.radius.card,
    backgroundColor: tokens.paper,
    gap: 8,
    maxWidth: 320,
  },
  heading: { fontSize: 17, fontWeight: "600", color: tokens.ink },
  title: { fontSize: 17, fontWeight: "600", color: tokens.ink },
  copy: { fontSize: 14, color: "#636366", lineHeight: 20 },
  hint: { fontSize: 12, color: "#8E8E93" },
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
  buttonSecondary: {
    minHeight: 44,
    borderRadius: 12,
    backgroundColor: tokens.paper,
    borderWidth: 1,
    borderColor: tokens.line,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 16,
  },
  buttonLabel: { color: tokens.paper, fontWeight: "600" },
  buttonLabelDark: { color: tokens.ink, fontWeight: "600" },
  error: { color: "#EB5757" },
});
