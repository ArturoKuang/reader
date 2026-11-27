import { StyleSheet, Text, View } from "react-native";
import { tokens } from "../ui/tokens";
import type { OpenConflict } from "./wire";

/**
 * Read-only. Reader on the Mac resolves the conflict; this phone does not.
 */
export function ConflictCard({ conflict }: { conflict: OpenConflict }) {
  const kind = conflict.kind === "note" ? "note" : conflict.kind === "word" ? "word" : "highlight";
  return (
    <View
      accessibilityLabel={`conflict ${conflict.conflictId}`}
      testID={`conflict-card-${conflict.conflictId}`}
      style={styles.card}
    >
      <Text style={styles.badge}>Resolve on Mac</Text>
      <Text style={styles.heading}>
        This {kind} changed on {conflict.sides.length} devices
      </Text>
      <Text style={styles.body}>Both versions are kept. Pick one in Reader on your Mac.</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    padding: 10,
    borderRadius: tokens.radius.card,
    borderWidth: 1,
    borderColor: tokens.syncStatus.conflict.dot,
    gap: 4,
  },
  badge: {
    alignSelf: "flex-start",
    color: tokens.syncStatus.conflict.dot,
    fontSize: tokens.type.caption.size,
    fontWeight: "600",
  },
  heading: { color: tokens.ink, fontSize: tokens.type.caption.size, fontWeight: "600" },
  body: { color: "#636366", fontSize: tokens.type.caption.size, lineHeight: tokens.type.caption.lineHeight },
});
