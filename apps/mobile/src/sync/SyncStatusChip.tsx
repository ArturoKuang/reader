import { useState } from "react";
import { Modal, Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { conflictVersionsLabel, tokens } from "../ui/tokens";
import type { SyncStatus } from "./status";
import { ConflictCard } from "./ConflictCard";
import type { OpenConflict } from "./wire";
import { PairingScan } from "../ui/PairingScan";

const chip = tokens.syncStatus;

function statusLabel(status: SyncStatus): string {
  if (status.state === "conflict") return conflictVersionsLabel(status.conflictCount);
  return chip[status.state].label;
}

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
        <Text style={styles.chipLabel}>{statusLabel(status)}</Text>
      </View>
    </Pressable>
  );
}

/**
 * Chip plus the pairing / sync sheet, the storage-full actions, and
 * the read-only conflict cards. Mounted from the library header.
 * The opened card is a Modal bottom sheet so the header row never reflows.
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
  const insets = useSafeAreaInsets();
  const [open, setOpen] = useState(false);
  const [url, setUrl] = useState("");
  const [scanning, setScanning] = useState(false);
  const unpaired = status.state === "unpaired";

  function closeSheet() {
    setScanning(false);
    setOpen(false);
  }

  function toggleSheet() {
    if (status.state === "error") onRetry?.();
    setOpen((value) => !value);
  }

  function reviewInNotebook() {
    const conflict = conflicts[0];
    if (!conflict) return;
    closeSheet();
    onOpenConflict?.(conflict);
  }

  return (
    <View>
      <SyncStatusChip status={status} onPress={toggleSheet} />
      <Modal transparent animationType="slide" visible={open} onRequestClose={closeSheet}>
        <View style={styles.modalRoot}>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Dismiss sync sheet"
            testID="sync-sheet-backdrop"
            onPress={closeSheet}
            style={styles.backdrop}
          />
          <View
            testID="sync-sheet"
            accessibilityLabel="sync sheet"
            style={[styles.sheet, { paddingBottom: insets.bottom + 16 }]}
          >
            <View style={styles.handle} accessibilityLabel="Dismiss handle" />
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
            {conflicts.length > 0 ? (
              <View style={styles.block}>
                {conflicts.map((conflict) => (
                  <ConflictCard key={conflict.conflictId} conflict={conflict} />
                ))}
                {onOpenConflict ? (
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel="Review in Notebook"
                    testID="review-in-notebook"
                    onPress={reviewInNotebook}
                    style={styles.buttonSecondary}
                  >
                    <Text style={styles.buttonLabelDark}>Review in Notebook</Text>
                  </Pressable>
                ) : null}
              </View>
            ) : null}
          </View>
        </View>
      </Modal>
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
  modalRoot: { flex: 1, justifyContent: "flex-end" },
  backdrop: {
    ...StyleSheet.absoluteFill,
    backgroundColor: "rgba(0, 0, 0, 0.2)",
  },
  sheet: {
    backgroundColor: tokens.paper,
    borderTopLeftRadius: tokens.radius.sheet,
    borderTopRightRadius: tokens.radius.sheet,
    padding: tokens.space[3],
    gap: tokens.space[2],
  },
  handle: {
    alignSelf: "center",
    width: 36,
    height: 5,
    borderRadius: 3,
    backgroundColor: tokens.line,
    marginBottom: tokens.space[1],
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
