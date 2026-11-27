import { StatusBar } from "expo-status-bar";
import { StyleSheet } from "react-native";
import { SafeAreaProvider, SafeAreaView } from "react-native-safe-area-context";
import { installCryptoPolyfill } from "./src/sync/cryptoPolyfill";
import { SyncProvider } from "./src/sync/SyncProvider";
import { AppShell } from "./src/ui/AppShell";
import { tokens } from "./src/ui/tokens";

installCryptoPolyfill();

export default function App() {
  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.root} edges={["top", "left", "right"]}>
        <StatusBar style="dark" />
        <SyncProvider>
          <AppShell />
        </SyncProvider>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: tokens.canvas },
});
