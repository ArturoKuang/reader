import { Pressable, StyleSheet, Text, View } from "react-native";
import type { SyncStatus } from "./status";

/**
 * Debug surface for the derived status. The real chip maps labels and
 * colors onto `status` later. Tap is wired for the error state's retry.
 */
export function SyncStatusChip({ status, onPress }: { status: SyncStatus; onPress?: () => void }) {
  return (
    <Pressable accessibilityRole="button" accessibilityLabel={`sync ${status.state}`} onPress={onPress}>
      <View style={styles.row}>
        <Text>{status.state}</Text>
        <Text>{status.pendingCount} pending</Text>
        <Text>{status.conflictCount} conflicts</Text>
        <Text>{status.lastSyncedAt ?? "never"}</Text>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: "row", gap: 8 },
});
