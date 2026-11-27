import type { PairingParts } from "./wire";

/** Tailscale HTTPS origin for the Mac mini, including the `/v1/reader` prefix. */
export const PRODUCTION_BASE_URL = "https://arturos-mac-mini.tail8dc761.ts.net/v1/reader";

/** Android emulator loopback to the host's reader-sync port. */
export const EMULATOR_BASE_URL = "http://10.0.2.2:8789/v1/reader";

/**
 * `readersync://pair?v=2&url=<base URL>&token=<t>&server=<serverId>`
 * `v=1` is rejected. The phone stores `url` and does not invent a host or port.
 */
export function parsePairingUrl(url: string): PairingParts {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error("pairing QR is not a valid URL");
  }
  if (parsed.protocol !== "readersync:") {
    throw new Error("pairing url must use readersync:");
  }
  const v = parsed.searchParams.get("v");
  if (v === "1") {
    throw new Error("pairing QR v=1 is no longer supported; scan a v=2 code");
  }
  if (v !== "2") {
    throw new Error("pairing QR version is missing or unsupported");
  }
  const base = parsed.searchParams.get("url");
  const token = parsed.searchParams.get("token");
  const serverId = parsed.searchParams.get("server");
  if (!base || !token || !serverId) {
    throw new Error("pairing QR is missing url, token, or server");
  }
  let destination: URL;
  try {
    destination = new URL(base);
  } catch {
    throw new Error("pairing base URL is not a valid URL");
  }
  if (destination.protocol !== "https:" && destination.protocol !== "http:") {
    throw new Error("pairing base URL must be http or https");
  }
  return { v: "2", url: stripTrailingSlash(base), token, serverId };
}

/** Join a rev 3.1 path onto a stored base URL. A trailing slash on the base is removed. */
export function joinBase(baseUrl: string, path: string): string {
  const base = stripTrailingSlash(baseUrl);
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `${base}${suffix}`;
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}
