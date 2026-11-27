import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
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
 * Chip plus the storage-full sheet and the read-only conflict cards.
 * Mounted from the library header.
 */
export function SyncChrome({
  status,
  conflicts,
  onCheckAgain,
  onRetry,
}: {
  status: SyncStatus;
  conflicts: readonly OpenConflict[];
  onCheckAgain?: () => void;
  onRetry?: () => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <View>
      <SyncStatusChip
        status={status}
        onPress={() => {
          if (status.state === "error") onRetry?.();
          else setOpen(true);
        }}
      />
      {open && status.state === "storageFull" ? (
        <View accessibilityLabel="storage full sheet">
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
      {open && status.state === "conflict"
        ? conflicts.map((conflict) => <ConflictCard key={conflict.conflictId} conflict={conflict} />)
        : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", gap: 8 },
  dot: { width: 8, height: 8, borderRadius: 8 },
});
