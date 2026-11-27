const fs = require("fs");
const path = require("path");
const { withDangerousMod, withInfoPlist } = require("expo/config-plugins");

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
function withAndroidDebugCleartext(config) {
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

/** Allow Metro and the local 127.0.0.1 test sync server over HTTP. */
function withIosLocalNetworking(config) {
  return withInfoPlist(config, (mod) => {
    const ats = mod.modResults.NSAppTransportSecurity ?? {};
    ats.NSAllowsLocalNetworking = true;
    const domains = ats.NSExceptionDomains ?? {};
    domains.localhost = {
      NSExceptionAllowsInsecureHTTPLoads: true,
      NSIncludesSubdomains: true,
    };
    domains["127.0.0.1"] = {
      NSExceptionAllowsInsecureHTTPLoads: true,
      NSIncludesSubdomains: false,
    };
    ats.NSExceptionDomains = domains;
    mod.modResults.NSAppTransportSecurity = ats;
    return mod;
  });
}

function withDebugCleartext(config) {
  return withIosLocalNetworking(withAndroidDebugCleartext(config));
}

module.exports = withDebugCleartext;
