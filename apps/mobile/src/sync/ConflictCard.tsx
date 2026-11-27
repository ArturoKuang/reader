import { Text, View } from "react-native";
import type { OpenConflict } from "./wire";

/**
 * Read-only. Reader on the Mac resolves the conflict; this phone does not.
 */
export function ConflictCard({ conflict }: { conflict: OpenConflict }) {
  return (
    <View accessibilityLabel={`conflict ${conflict.conflictId}`}>
      <Text>
        This {conflict.kind} changed on {conflict.sides.length} devices
      </Text>
      <Text>Both versions are kept. Pick one in Reader on your Mac.</Text>
      {conflict.sides.map((side) => (
        <Text key={side.changeId}>{side.changeId}</Text>
      ))}
    </View>
  );
}
