import type { PairingParts } from "./wire";

/**
 * Documented readersync port on the Mac mini. Another service already
 * binds 8787. This constant is for examples, tests, and docs only.
 * The phone dials the host and port from the pairing QR and never
 * substitutes this value.
 */
export const SYNC_PORT = 8788;

/**
 * `readersync://pair?v=1&host=<ip>&port=8788&token=<t>&server=<serverId>`
 * Host and port are required. A missing port is not filled in with 8788.
 */
export function parsePairingUrl(url: string): PairingParts {
  const parsed = new URL(url);
  if (parsed.protocol !== "readersync:") {
    throw new Error("pairing url must use readersync:");
  }
  const v = parsed.searchParams.get("v");
  const host = parsed.searchParams.get("host");
  const portText = parsed.searchParams.get("port");
  const token = parsed.searchParams.get("token");
  const serverId = parsed.searchParams.get("server");
  const port = portText ? Number(portText) : NaN;
  if (v !== "1" || !host || !token || !serverId || !Number.isInteger(port) || port <= 0) {
    throw new Error("pairing url is missing v, host, port, token, or server");
  }
  return { v, host, port, token, serverId };
}

export function endpointUrl(host: string, port: number): string {
  return `http://${host}:${port}`;
}
