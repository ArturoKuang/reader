# Phone network

Pairing QR (spec rev 3.2):

```
readersync://pair?v=2&url=https://arturos-mac-mini.tail8dc761.ts.net/v1/reader&token=<t>&server=<serverId>
```

`v=1` is rejected. The phone stores `url` as the base and joins rev 3.1 paths under it, after stripping a trailing slash:

`https://arturos-mac-mini.tail8dc761.ts.net/v1/reader/v1/changes`

The emulator test base is `http://10.0.2.2:8789/v1/reader`. Production is HTTPS through Tailscale. Release builds do not allow cleartext.

The credential from `POST /v1/pairing/redeem` is stored with `expo-secure-store`. The outbox snapshot is stored in AsyncStorage under `readersync.state`.

## Android cleartext (debug only)

`plugins/withDebugCleartext.js` writes a debug source-set network security config. It allows cleartext only for `10.0.2.2`, `localhost`, and `127.0.0.1`. The release manifest is unchanged.
