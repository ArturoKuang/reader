import XCTest
import ReaderCore
import ReaderSync

final class SyncClientTests: XCTestCase {
    func testPairingIssuesQRAndStoresCredential() async throws {
        let transport = MockTransport()
        transport.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/pairing/tokens") {
                XCTAssertEqual((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["kind"] as? String, "mac")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Tailscale-User-Login"), "arturo@local")
                return jsonResponse(200, [
                    "token": "MACTOKEN",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=MACTOKEN&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "secret-cred", "serverId": "srv_test", "kind": "mac"])
            }
            return jsonResponse(404, [:])
        }
        let (engine, credentials, _) = try makeEngine(transport: transport)
        let redeemed = try await engine.ensureMacPaired()
        XCTAssertEqual(redeemed.kind, "mac")
        XCTAssertEqual(credentials.load(account: SyncKeychainAccount.credential), "secret-cred")
        XCTAssertEqual(engine.http.credential, "secret-cred")
    }

    func testPhoneQRUsesV2() async throws {
        let transport = MockTransport()
        var kinds: [String] = []
        transport.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/v1/pairing/tokens") {
                let kind = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["kind"] as? String ?? ""
                kinds.append(kind)
                return jsonResponse(200, [
                    "token": kind.uppercased() + "TOK",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "qr": "readersync://pair?v=2&url=http://127.0.0.1:8789/v1/reader&token=\(kind.uppercased())TOK&server=srv_test",
                ])
            }
            if path.hasSuffix("/v1/pairing/redeem") {
                return jsonResponse(200, ["deviceId": "dev-mac", "credential": "secret-cred", "serverId": "srv_test", "kind": "mac"])
            }
            return jsonResponse(404, [:])
        }
        let (engine, _, _) = try makeEngine(transport: transport)
        let issued = try await engine.issuePhoneQR()
        XCTAssertEqual(kinds, ["mac", "phone"])
        let qr = try PairingQR.parse(issued.qr)
        XCTAssertEqual(qr.version, 2)
        XCTAssertEqual(qr.token, "PHONETOK")
    }

    func testUnreachableSetsErrorState() async throws {
        let transport = MockTransport()
        transport.handler = { _ in
            throw SyncAPIError.network("offline")
        }
        let (engine, credentials, _) = try makeEngine(transport: transport)
        try credentials.save(account: SyncKeychainAccount.credential, secret: "cred")
        engine.http.credential = "cred"
        do {
            try await engine.sync()
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(engine.status().state, .error)
            XCTAssertEqual(engine.status().label, "Can't reach Mac mini")
        }
    }
}
