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

    func testWorkspaceOptionParsingAndFallback() {
        let parsed = AgyWorkspaceOption.parseList([
            [
                "path": "/Users/demo/agy-mobile/",
                "name": "agy-mobile",
                "displayPath": "~/agy-mobile",
                "lastUsed": 1_763_600_000_000.0,
                "sessionCount": 4,
                "source": "recent",
                "isDefault": false,
            ],
            [
                "path": "/Users/demo/agy-mobile",
                "name": "duplicate",
            ],
            [
                "path": "/Users/demo/pi-mobile",
                "source": "project",
            ],
        ])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].path, "/Users/demo/agy-mobile")
        XCTAssertEqual(parsed[0].displayPath, "~/agy-mobile")
        XCTAssertEqual(parsed[0].sessionCount, 4)
        XCTAssertTrue(parsed[0].isRecentGroup)
        XCTAssertEqual(parsed[1].name, "pi-mobile")
        XCTAssertFalse(parsed[1].isRecentGroup)

        let fallback = AgyWorkspaceOption.fallback(
            fromSessions: [
                ["path": "s1", "cwd": "/Users/demo/pi-mobile", "mtime": 1_763_500_000_000.0],
                ["path": "s2", "cwd": "/Users/demo/agy-mobile", "mtime": 1_763_600_000_000.0],
            ],
            currentCwd: "/Users/demo/agy-mobile",
            defaultCwd: "/Users/demo"
        )
        XCTAssertEqual(fallback.map(\.path), ["/Users/demo/agy-mobile", "/Users/demo/pi-mobile", "/Users/demo"])
        XCTAssertEqual(fallback.last?.isDefault, true)
    }

    @MainActor
    func testRelayClientSilentGraceRecoversWithoutError() async throws {
        let token = String(repeating: "a", count: 64)
        let store = makeSavedPairingStore(token: token)
        var sockets: [FakeRelaySocket] = []
        let client = RelayClient(
            endpoint: nil,
            store: store,
            pongTimeout: .seconds(5),
            foregroundProbeTimeout: .milliseconds(100),
            heartbeatInterval: .seconds(30),
            reconnectGracePeriod: .milliseconds(300),
            initialReconnectDelay: .milliseconds(25),
            maxReconnectDelay: .milliseconds(100),
            enableNetworkMonitor: false
        ) { _ in
            let sock = FakeRelaySocket()
            sockets.append(sock)
            return sock
        }

        var observedStates: [(ConnectionState, String?, ReconnectPhase)] = []
        client.onConnectionChange = { [weak client] state, error in
            observedStates.append((state, error, client?.reconnectPhase ?? .none))
        }

        client.connectIfNeeded()
        try await waitUntil { sockets.count == 1 }
        sockets[0].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }
        XCTAssertEqual(client.reconnectPhase, .none)

        // 模拟瞬断（切网/信号抖动）：应进入静默宽限期，不出现 .error 或错误文案
        sockets[0].failReceive(URLError(.networkConnectionLost))
        try await waitUntil { sockets.count == 2 }
        XCTAssertEqual(client.reconnectPhase, .silentGrace)
        XCTAssertNil(client.lastError)
        XCTAssertNotEqual(client.state, .error)

        // 在宽限期内恢复连接
        sockets[1].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }
        XCTAssertEqual(client.reconnectPhase, .none)
        XCTAssertNil(client.lastError)
        XCTAssertFalse(observedStates.contains { $0.0 == .error || $0.1 != nil || $0.2 == .retryingGentle })
    }

    @MainActor
    func testRelayClientEscalatesToGentleNoticeAfterGracePeriodAndRecovers() async throws {
        let token = String(repeating: "b", count: 64)
        let store = makeSavedPairingStore(token: token)
        var sockets: [FakeRelaySocket] = []
        let client = RelayClient(
            endpoint: nil,
            store: store,
            pongTimeout: .seconds(5),
            foregroundProbeTimeout: .milliseconds(80),
            heartbeatInterval: .seconds(30),
            reconnectGracePeriod: .milliseconds(120),
            initialReconnectDelay: .milliseconds(30),
            maxReconnectDelay: .milliseconds(60),
            enableNetworkMonitor: false
        ) { _ in
            let sock = FakeRelaySocket()
            sockets.append(sock)
            return sock
        }

        client.connectIfNeeded()
        try await waitUntil { sockets.count == 1 }
        sockets[0].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }

        // 持续断开超过宽限期
        sockets[0].failReceive(URLError(.notConnectedToInternet))
        try await waitUntil { client.reconnectPhase == .silentGrace }
        XCTAssertNil(client.lastError)

        // 等待宽限期结束 -> 进入温和提示态
        try await waitUntil(timeout: .seconds(2)) { client.reconnectPhase == .retryingGentle }
        XCTAssertNil(client.lastError)
        XCTAssertNotEqual(client.state, .error)

        // 网络恢复，下一次重试成功 -> 清除温和提示
        try await waitUntil(timeout: .seconds(2)) { sockets.count >= 2 }
        sockets.last?.deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }
        XCTAssertEqual(client.reconnectPhase, .none)
    }

    @MainActor
    func testRelayClientBackgroundDisconnectGetsFreshSilentGraceOnForeground() async throws {
        let token = String(repeating: "c", count: 64)
        let store = makeSavedPairingStore(token: token)
        var sockets: [FakeRelaySocket] = []
        let client = RelayClient(
            endpoint: nil,
            store: store,
            pongTimeout: .seconds(5),
            foregroundProbeTimeout: .milliseconds(80),
            heartbeatInterval: .seconds(30),
            reconnectGracePeriod: .milliseconds(250),
            initialReconnectDelay: .milliseconds(25),
            maxReconnectDelay: .milliseconds(60),
            enableNetworkMonitor: false
        ) { _ in
            let sock = FakeRelaySocket()
            sockets.append(sock)
            return sock
        }

        client.connectIfNeeded()
        try await waitUntil { sockets.count == 1 }
        sockets[0].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }

        // 切入后台后连接被系统回收
        client.setForeground(false)
        sockets[0].failReceive(URLError(.networkConnectionLost))
        try await Task.sleep(for: .milliseconds(320))
        // 后台不应消耗宽限期，也不应提前升级为 retryingGentle 或重连
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(client.reconnectPhase, .silentGrace)

        // 回到前台：立刻无感发起重连并处于静默宽限期
        client.setForeground(true)
        try await waitUntil { sockets.count == 2 }
        XCTAssertEqual(client.reconnectPhase, .silentGrace)
        XCTAssertNil(client.lastError)

        sockets[1].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }
        XCTAssertEqual(client.reconnectPhase, .none)
    }

    @MainActor
    func testRelayClientNetworkChangeInterruptsBackoffAndFatalAuthBypassesGrace() async throws {
        let token = String(repeating: "d", count: 64)
        let store = makeSavedPairingStore(token: token)
        var sockets: [FakeRelaySocket] = []
        let client = RelayClient(
            endpoint: nil,
            store: store,
            pongTimeout: .seconds(5),
            foregroundProbeTimeout: .milliseconds(80),
            heartbeatInterval: .seconds(30),
            reconnectGracePeriod: .milliseconds(300),
            initialReconnectDelay: .seconds(10),
            maxReconnectDelay: .seconds(10),
            enableNetworkMonitor: false
        ) { _ in
            let sock = FakeRelaySocket()
            sockets.append(sock)
            return sock
        }

        client.handleNetworkPathChange(.init(isSatisfied: true, interfaceNames: ["en0"]))
        client.connectIfNeeded()
        try await waitUntil { sockets.count == 1 }
        sockets[0].deliverJSON(["type": "paired", "deviceToken": token])
        try await waitUntil { client.isConnected }

        // 断线后进入 10s 长退避，但切网（Wi-Fi -> 5G）应立刻唤醒重连
        sockets[0].failReceive(URLError(.networkConnectionLost))
        try await waitUntil { client.reconnectPhase == .silentGrace }
        XCTAssertEqual(sockets.count, 1)

        client.handleNetworkPathChange(.init(isSatisfied: true, interfaceNames: ["pdp_ip0"], isExpensive: true))
        try await waitUntil { sockets.count == 2 }

        // 配对失效错误必须跳过宽限期立刻进入 .error
        sockets[1].deliverJSON(["type": "error", "message": "not paired"])
        try await waitUntil { client.state == .error }
        XCTAssertEqual(client.reconnectPhase, .none)
        XCTAssertEqual(client.lastError, "not paired")
    }

    private func makeSavedPairingStore(token: String) -> PairingStore {
        let gwPub = samplePub
        let key = E2EKey(gatewayPublicKey: gwPub)!
        var saved: String?
        let store = PairingStore(
            read: { saved },
            write: { saved = $0; return true },
            clear: { saved = nil }
        )
        _ = store.save(endpoint: URL(string: "ws://127.0.0.1:8790/agy/client")!, token: token, key: key)
        return store
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(1), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class FakeRelaySocket: RelaySocket {
    private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private(set) var sentMessages: [String] = []
    var pingError: Error?

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .string(let text) = message {
            sentMessages.append(text)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !queued.isEmpty {
            return try queued.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.receiveContinuation = continuation
        }
    }

    func ping(_ completion: @escaping @Sendable (Error?) -> Void) {
        completion(pingError)
    }

    func deliverJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let msg = URLSessionWebSocketTask.Message.string(text)
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: msg)
        } else {
            queued.append(.success(msg))
        }
    }

    func failReceive(_ error: Error) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(throwing: error)
        } else {
            queued.append(.failure(error))
        }
    }
}
