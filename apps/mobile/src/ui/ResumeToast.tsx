import { Pressable, StyleSheet, Text, View } from "react-native";
import { tokens } from "./tokens";
import type { PositionToastView } from "./resumeOffer";

export function PositionToast({
  toast,
  onAction,
  onDismiss,
}: {
  toast: PositionToastView;
  onAction: () => void;
  onDismiss: () => void;
}) {
  return (
    <View testID="position-toast" accessibilityLabel="position toast" style={styles.toast}>
      <Text style={styles.lead}>{toast.lead}</Text>
      <Pressable accessibilityRole="button" accessibilityLabel={toast.action} onPress={onAction}>
        <Text style={styles.action}>{toast.action}</Text>
      </Pressable>
      <Pressable accessibilityRole="button" accessibilityLabel="Dismiss position toast" onPress={onDismiss}>
        <Text style={styles.dismiss}>OK</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  toast: {
    position: "absolute",
    left: 14,
    right: 14,
    bottom: 60,
    paddingVertical: 10,
    paddingHorizontal: 12,
    borderRadius: tokens.radius.card,
    backgroundColor: tokens.paper,
    borderWidth: 1,
    borderColor: tokens.line,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 8,
  },
  lead: { flex: 1, fontSize: 13, color: tokens.ink },
  action: { color: tokens.accent, fontWeight: "600", fontSize: 13 },
  dismiss: { color: "#636366", fontSize: 13 },
});
