import { useEffect, useState, type ComponentType } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { tokens } from "./tokens";

type Permission = { granted: boolean } | null;
type RequestPermission = () => Promise<{ granted: boolean }>;

interface CameraViewProps {
  style?: object;
  facing?: "back" | "front";
  barcodeScannerSettings?: { barcodeTypes: string[] };
  onBarcodeScanned?: (event: { data: string }) => void;
}

interface CameraModule {
  CameraView: ComponentType<CameraViewProps>;
  useCameraPermissions: () => [Permission, RequestPermission];
}

function loadCamera(): CameraModule | null {
  try {
    // Optional: present on device builds, often missing in Jest / headless emulator.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    return require("expo-camera") as CameraModule;
  } catch {
    return null;
  }
}

function Scanner({
  camera,
  onCode,
}: {
  camera: CameraModule;
  onCode: (url: string) => void;
}) {
  const [permission, requestPermission] = camera.useCameraPermissions();
  const [denied, setDenied] = useState(false);
  useEffect(() => {
    if (permission?.granted) return;
    void requestPermission().then((result) => {
      if (!result.granted) setDenied(true);
    });
  }, [permission?.granted, requestPermission]);
  if (!permission?.granted || denied) {
    return <Text style={styles.copy}>Camera permission is needed to scan a pairing code. Paste the link instead.</Text>;
  }
  const CameraView = camera.CameraView;
  return (
    <CameraView
      style={styles.preview}
      facing="back"
      barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
      onBarcodeScanned={(event) => {
        if (typeof event.data === "string" && event.data.startsWith("readersync:")) onCode(event.data);
      }}
    />
  );
}

/**
 * Camera-permission-graceful QR scanner. Falls back to paste when the
 * camera module or permission is unavailable (emulator, Maestro, Jest).
 */
export function PairingScan({ onCode, onCancel }: { onCode: (url: string) => void; onCancel: () => void }) {
  const camera = loadCamera();
  return (
    <View style={styles.block} testID="pair-scanner">
      {camera ? (
        <Scanner camera={camera} onCode={onCode} />
      ) : (
        <Text style={styles.copy}>Camera is not available on this device. Paste the pairing link instead.</Text>
      )}
      <Pressable accessibilityRole="button" accessibilityLabel="Cancel scan" onPress={onCancel} style={styles.button}>
        <Text style={styles.buttonLabel}>Paste a link instead</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  block: { gap: 8 },
  preview: { width: "100%", height: 220, borderRadius: 16, overflow: "hidden" },
  copy: { fontSize: 14, color: "#636366", lineHeight: 20 },
  button: {
    minHeight: tokens.touchTarget,
    borderRadius: tokens.radius.card,
    backgroundColor: tokens.paper,
    borderWidth: 1,
    borderColor: tokens.line,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonLabel: { color: tokens.ink, fontWeight: "600" },
});
