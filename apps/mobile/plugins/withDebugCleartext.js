const fs = require("fs");
const path = require("path");
const { withDangerousMod } = require("expo/config-plugins");

const XML = `<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
  <base-config cleartextTrafficPermitted="false" />
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">10.0.2.2</domain>
    <domain includeSubdomains="false">localhost</domain>
    <domain includeSubdomains="false">127.0.0.1</domain>
  </domain-config>
</network-security-config>
`;

/** Debug builds may talk to the emulator host. Release builds stay HTTPS-only. */
function withDebugCleartext(config) {
  return withDangerousMod(config, [
    "android",
    (mod) => {
      const root = mod.modRequest.platformProjectRoot;
      const xmlDir = path.join(root, "app/src/debug/res/xml");
      fs.mkdirSync(xmlDir, { recursive: true });
      fs.writeFileSync(path.join(xmlDir, "network_security_config.xml"), XML);
      const manifestPath = path.join(root, "app/src/debug/AndroidManifest.xml");
      const attr = 'android:networkSecurityConfig="@xml/network_security_config"';
      if (!fs.existsSync(manifestPath)) {
        fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
        fs.writeFileSync(
          manifestPath,
          `<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application ${attr} />
</manifest>
`,
        );
        return mod;
      }
      let manifest = fs.readFileSync(manifestPath, "utf8");
      if (!manifest.includes("networkSecurityConfig")) {
        manifest = manifest.includes("<application")
          ? manifest.replace("<application", `<application ${attr}`)
          : manifest.replace("</manifest>", `  <application ${attr} />\n</manifest>`);
      }
      manifest = manifest.replace(/\s*android:usesCleartextTraffic="true"/, "");
      manifest = manifest.replace(/\s*tools:replace="android:usesCleartextTraffic"/, "");
      fs.writeFileSync(manifestPath, manifest);
      return mod;
    },
  ]);
}

module.exports = withDebugCleartext;
