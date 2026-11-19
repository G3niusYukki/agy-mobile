import CryptoKit
import XCTest
@testable import AgyMobileCore

final class AgyMobileCoreTests: XCTestCase {
    private var samplePub: String {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64UrlEncoded
    }

    func testPairingLinkSupportsRelayAndDirectLANAndTailscale() throws {
        let token = String(repeating: "a", count: 32)
        let pub = samplePub

        let relay = try PairingLink("https://relay.example.com/agy/pair#\(token).\(pub)")
        XCTAssertEqual(relay.endpoint.absoluteString, "wss://relay.example.com/agy/client")
        XCTAssertEqual(relay.transportKind, .relay)

        let lan = try PairingLink("http://192.168.1.24:8790/agy/pair#\(token).\(pub)")
        XCTAssertEqual(lan.endpoint.absoluteString, "ws://192.168.1.24:8790/agy/client")
        XCTAssertEqual(lan.transportKind, .direct)

        let ts = try PairingLink("http://100.88.12.34:8790/agy/pair#\(token).\(pub)")
        XCTAssertEqual(ts.endpoint.absoluteString, "ws://100.88.12.34:8790/agy/client")
        XCTAssertEqual(ts.transportKind, .direct)

        let tsMagic = try PairingLink("http://mac-studio.tail1234.ts.net:8790/agy/pair#\(token).\(pub)")
        XCTAssertEqual(tsMagic.transportKind, .direct)

        // 公网明文 HTTP 必须被拒绝
        XCTAssertThrowsError(try PairingLink("http://relay.example.com/agy/pair#\(token).\(pub)"))
        XCTAssertThrowsError(try PairingLink("http://8.8.8.8:8790/agy/pair#\(token).\(pub)"))
    }

    func testE2ERoundTrip() throws {
        let gwPriv = Curve25519.KeyAgreement.PrivateKey()
        let gwPub = gwPriv.publicKey.rawRepresentation.base64UrlEncoded
        let client = try XCTUnwrap(E2EKey(gatewayPublicKey: gwPub))
        let peer = try XCTUnwrap(E2EKey(privateKeyBase64Url: gwPriv.rawRepresentation.base64UrlEncoded, gatewayPublicKey: client.publicKey))
        let sealed = try XCTUnwrap(client.seal(["type": "prompt", "message": "hello agy"]))
        let opened = try XCTUnwrap(peer.open(sealed))
        XCTAssertEqual(opened["message"] as? String, "hello agy")
    }

    func testProjectionParsesAgyDisplayNames() {
        let data: [String: Any] = [
            "models": [
                ["provider": "Google", "id": "gemini-4-neon-xhigh", "displayName": "Gemini 4 Neon (XHigh)"],
                ["provider": "Anthropic", "id": "claude-opus-5-5-high", "displayName": "Claude Opus 5.5 (High)"],
            ],
        ]
        let options = AgyProjection.modelOptions(from: data)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].displayName, "Gemini 4 Neon (XHigh)")
        XCTAssertEqual(options[1].provider, "Anthropic")
    }

    func testOfficialRemoteLinkParsesDesktopQRAndRejectsSpoofedURLs() throws {
        let chooser = "https://accounts.google.com/AccountChooser?Email=user%40example.com&continue=https%3A%2F%2Fantigravity.google.com%2Fr%2F3dc8f9b6-c6a3-4b96-9214-036850fb69f3-v2"
        let parsed = try XCTUnwrap(OfficialRemoteLink(chooser))
        XCTAssertEqual(parsed.deviceID, "3dc8f9b6-c6a3-4b96-9214-036850fb69f3-v2")
        XCTAssertEqual(parsed.targetURL.absoluteString, "https://antigravity.google.com/r/3dc8f9b6-c6a3-4b96-9214-036850fb69f3-v2")
        XCTAssertEqual(parsed.launchURL.host, "accounts.google.com")

        let direct = try XCTUnwrap(OfficialRemoteLink("https://antigravity.google.com/r/my-mac-01"))
        XCTAssertEqual(direct.deviceID, "my-mac-01")

        XCTAssertNil(OfficialRemoteLink("http://antigravity.google.com/r/my-mac-01"))
        XCTAssertNil(OfficialRemoteLink("https://evil.example.com/r/my-mac-01"))
        XCTAssertNil(OfficialRemoteLink("https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fevil.example.com%2Fr%2F1"))
    }
}
