import XCTest
import ReaderSync

final class QRPairingTests: XCTestCase {
    let base = URL(string: "https://arturos-mac-mini.tail8dc761.ts.net/v1/reader")!

    func testGenerateV2PayloadKeepsURLPunctuation() throws {
        let qr = PairingQR.make(baseURL: base, token: "ABC234", serverId: "srv_1")
        let payload = qr.payload
        XCTAssertTrue(payload.hasPrefix("readersync://pair?"))
        XCTAssertTrue(payload.contains("v=2"))
        XCTAssertTrue(payload.contains("url=https://arturos-mac-mini.tail8dc761.ts.net/v1/reader"))
        XCTAssertFalse(payload.contains("url=https%3A%2F%2F"), "url should leave : and / unescaped")
        XCTAssertTrue(payload.contains("token=ABC234"))
        XCTAssertTrue(payload.contains("server=srv_1"))
    }

    func testParseRoundTrip() throws {
        let original = PairingQR.make(baseURL: base, token: "QRS7TOKEN", serverId: "srv_abc")
        let parsed = try PairingQR.parse(original.payload)
        XCTAssertEqual(parsed.version, 2)
        XCTAssertEqual(parsed.url, base)
        XCTAssertEqual(parsed.token, "QRS7TOKEN")
        XCTAssertEqual(parsed.serverId, "srv_abc")
    }

    func testParseRejectsV1() {
        let v1 = "readersync://pair?v=1&host=arturos-mac-mini&port=8788&token=ABC&server=srv_1"
        XCTAssertThrowsError(try PairingQR.parse(v1)) { error in
            let api = error as? SyncAPIError
            XCTAssertTrue(api?.message.contains("v=1") == true)
        }
    }

    func testParseRejectsMissingFields() {
        XCTAssertThrowsError(try PairingQR.parse("readersync://pair?v=2&token=ABC"))
        XCTAssertThrowsError(try PairingQR.parse("https://example.com"))
        XCTAssertThrowsError(try PairingQR.parse("readersync://pair?v=3&url=https://x/v1/reader&token=t&server=s"))
    }

    func testParseDecodesPercentEncodedURL() throws {
        let raw = "readersync://pair?v=2&url=https://arturos-mac-mini.tail8dc761.ts.net/v1/reader&token=T1&server=srv_x"
        let parsed = try PairingQR.parse(raw)
        XCTAssertEqual(parsed.url.absoluteString, "https://arturos-mac-mini.tail8dc761.ts.net/v1/reader")
    }

    func testLoopbackTestURL() throws {
        let url = URL(string: "http://127.0.0.1:8789/v1/reader")!
        let qr = PairingQR.make(baseURL: url, token: "TOK", serverId: "srv_test")
        let parsed = try PairingQR.parse(qr.payload)
        XCTAssertEqual(parsed.url, url)
    }
}
