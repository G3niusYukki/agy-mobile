import Foundation
import Combine
import Network

@MainActor
public final class RelayClient: ObservableObject {
    @Published public private(set) var state: ConnectionState = .idle
    @Published public private(set) var lastError: String?
    @Published public private(set) var reconnectPhase: ReconnectPhase = .none
    @Published public private(set) var transportKind: ConnectionTransportKind?
    @Published public private(set) var endpointHost: String?

    public var onConnectionChange: ((ConnectionState, String?) -> Void)?
    public var onActionError: ((String) -> Void)?

    public var onEvent: (([String: Any]) -> Void)?
    public var onResponse: (([String: Any]) -> Void)?
    public var onPaired: ((String) -> Void)?
    public var onDeviceStatus: ((Bool) -> Void)?
    public var onSessionList: (([[String: Any]]) -> Void)?

    public var isConnected: Bool { state == .paired || state == .running }
    public var isSilentlyReconnecting: Bool { reconnectPhase == .silentGrace }
    public var isAutoReconnecting: Bool { reconnectPhase != .none }
    public var hasPairing: Bool { store.restore() != nil }

    struct NetworkPathSnapshot: Equatable, Sendable {
        let isSatisfied: Bool
        let interfaceNames: [String]
        let isExpensive: Bool
        let isConstrained: Bool

        init(isSatisfied: Bool, interfaceNames: [String], isExpensive: Bool = false, isConstrained: Bool = false) {
            self.isSatisfied = isSatisfied
            self.interfaceNames = interfaceNames.sorted()
            self.isExpensive = isExpensive
            self.isConstrained = isConstrained
        }

        init(_ path: NWPath) {
            self.init(
                isSatisfied: path.status == .satisfied,
                interfaceNames: path.availableInterfaces.map(\.name),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
        }
    }

    private enum Handshake {
        case pair(PairingLink)
        case resume(token: String, key: E2EKey, endpoint: URL)
    }

    private final class PathMonitorBox: @unchecked Sendable {
        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "agy-mobile.network-path-monitor", qos: .utility)

        init(onChange: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
            monitor.pathUpdateHandler = { path in
                onChange(NetworkPathSnapshot(path))
            }
            monitor.start(queue: queue)
        }

        deinit {
            monitor.cancel()
        }
    }

    private let configuredEndpoint: URL?
    private let store: PairingStore
    private let makeSocket: (URLRequest) -> any RelaySocket
    private var socket: (any RelaySocket)?
    private var receiver: Task<Void, Never>?
    private var handshake: Handshake?
    private var e2e: E2EKey?
    private let initialReconnectDelay: Duration
    private let maxReconnectDelay: Duration
    private var reconnectDelay: Duration
    private var retry: Task<Void, Never>?
    private var isForeground = true
    private var pendingForegroundReconnect = false
    private let pongTimeout: Duration
    private let foregroundProbeTimeout: Duration
    private let heartbeatInterval: Duration
    private let reconnectGracePeriod: Duration
    private var heartbeat: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var graceTargetPhase: ReconnectPhase = .retryingGentle
    private var probeID: UUID?
    private var pathMonitor: PathMonitorBox?
    private var lastNetworkPath: NetworkPathSnapshot?

    public convenience init(endpoint: String? = nil) {
        self.init(endpoint: endpoint, store: .keychain, makeSocket: Self.webSocket)
    }

    static func webSocket(for request: URLRequest) -> URLSessionWebSocketTask {
        let task = RelaySession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 12 * 1024 * 1024
        return task
    }

    init(
        endpoint: String?,
        store: PairingStore,
        pongTimeout: Duration = .seconds(8),
        foregroundProbeTimeout: Duration = .seconds(2),
        heartbeatInterval: Duration = .seconds(20),
        reconnectGracePeriod: Duration = .milliseconds(2500),
        initialReconnectDelay: Duration = .milliseconds(250),
        maxReconnectDelay: Duration = .seconds(15),
        enableNetworkMonitor: Bool = true,
        makeSocket: @escaping (URLRequest) -> any RelaySocket
    ) {
        self.configuredEndpoint = endpoint.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
        self.store = store
        self.makeSocket = makeSocket
        self.pongTimeout = pongTimeout
        self.foregroundProbeTimeout = foregroundProbeTimeout
        self.heartbeatInterval = heartbeatInterval
        self.reconnectGracePeriod = reconnectGracePeriod
        self.initialReconnectDelay = initialReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.reconnectDelay = initialReconnectDelay
        if let saved = store.restore() {
            self.transportKind = PairingLink.transportKind(for: saved.endpoint)
            self.endpointHost = saved.endpoint.host
        }
        if enableNetworkMonitor {
            self.pathMonitor = PathMonitorBox { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.handleNetworkPathChange(snapshot)
                }
            }
        }
    }

    private func publishConnection(state newState: ConnectionState, error newError: String?, reconnectPhase newPhase: ReconnectPhase) {
        let changed = state != newState || lastError != newError || reconnectPhase != newPhase
        lastError = newError
        reconnectPhase = newPhase
        state = newState
        if changed {
            onConnectionChange?(state, lastError)
        }
    }

    public func setForeground(_ foreground: Bool) {
        guard isForeground != foreground else { return }
        isForeground = foreground
        if !foreground {
            cancelHeartbeat()
            retry?.cancel()
            retry = nil
            graceTask?.cancel()
            graceTask = nil
            if !isConnected && (reconnectPhase != .none || state == .connecting) {
                pendingForegroundReconnect = true
            }
            return
        }

        // 回到前台：根据当前套接字状态决定快速探活还是带静默宽限期的无感重连
        if socket != nil, e2e != nil {
            if reconnectPhase == .silentGrace {
                startReconnectGrace(targetAfterGrace: graceTargetPhase, forceRestart: true)
            }
            probeSocket(timeout: foregroundProbeTimeout)
            return
        }
        if socket != nil, case .resume = handshake {
            pendingForegroundReconnect = false
            reconnectDelay = initialReconnectDelay
            openResumeConnection(silentGrace: true, forceRestartGrace: true)
            return
        }
        if socket == nil, hasPairing,
           pendingForegroundReconnect || reconnectPhase != .none || state == .idle {
            pendingForegroundReconnect = false
            reconnectDelay = initialReconnectDelay
            openResumeConnection(silentGrace: true, forceRestartGrace: true)
        }
    }

    func handleNetworkPathChange(_ snapshot: NetworkPathSnapshot) {
        let previous = lastNetworkPath
        lastNetworkPath = snapshot
        guard let previous, previous != snapshot else { return }
        guard isForeground, hasPairing else { return }
        if case .pair = handshake { return }

        if snapshot.isSatisfied {
            if socket == nil {
                reconnectDelay = initialReconnectDelay
                let keepGentle = reconnectPhase == .retryingGentle
                openResumeConnection(silentGrace: !keepGentle, forceRestartGrace: false)
            } else if e2e != nil {
                probeSocket(timeout: foregroundProbeTimeout)
            } else if case .resume = handshake {
                reconnectDelay = initialReconnectDelay
                let keepGentle = reconnectPhase == .retryingGentle
                openResumeConnection(silentGrace: !keepGentle, forceRestartGrace: false)
            }
        } else if socket != nil, e2e != nil {
            probeSocket(timeout: foregroundProbeTimeout)
        }
    }

    private func cancelHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
        probeID = nil
    }

    private func cancelGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    private func startReconnectGrace(targetAfterGrace: ReconnectPhase, forceRestart: Bool) {
        graceTargetPhase = targetAfterGrace
        if !isForeground {
            cancelGrace()
            reconnectPhase = .silentGrace
            pendingForegroundReconnect = true
            return
        }
        if !forceRestart {
            if reconnectPhase == .retryingGentle || reconnectPhase == .gatewayOfflineGentle {
                return
            }
            if reconnectPhase == .silentGrace, graceTask != nil {
                return
            }
        }
        cancelGrace()
        reconnectPhase = .silentGrace
        graceTask = Task { [weak self, reconnectGracePeriod] in
            do { try await Task.sleep(for: reconnectGracePeriod) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard self.isForeground, !self.isConnected, self.reconnectPhase == .silentGrace else { return }
            self.graceTask = nil
            self.publishConnection(state: self.state, error: nil, reconnectPhase: targetAfterGrace)
        }
    }

    private func scheduleHeartbeat() {
        cancelHeartbeat()
        guard isForeground, let socket, e2e != nil else { return }
        heartbeat = Task { [weak self, weak socket, heartbeatInterval] in
            do { try await Task.sleep(for: heartbeatInterval) } catch { return }
            guard let self, let socket, self.socket === socket else { return }
            self.probeSocket(timeout: self.pongTimeout)
        }
    }

    private func probeSocket(timeout: Duration? = nil) {
        guard isForeground, let socket, e2e != nil, probeID == nil else { return }
        heartbeat?.cancel()
        let effectiveTimeout = timeout ?? pongTimeout
        let id = UUID()
        probeID = id
        heartbeat = Task { [weak self, weak socket, effectiveTimeout] in
            do { try await Task.sleep(for: effectiveTimeout) } catch { return }
            guard let self, let socket, self.probeID == id else { return }
            self.transportLost(on: socket, message: "连接中断，正在重新连接…")
        }
        socket.ping { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket, self.probeID == id else { return }
                if let error { self.transportLost(on: socket, message: error.localizedDescription) }
                else { self.scheduleHeartbeat() }
            }
        }
    }

    public func connect() {
        reconnectDelay = initialReconnectDelay
        let keepGentle = reconnectPhase == .retryingGentle || reconnectPhase == .gatewayOfflineGentle
        openResumeConnection(silentGrace: false, forceRestartGrace: false, preserveGentle: keepGentle)
    }

    public func connectIfNeeded() {
        guard !isConnected, state != .connecting else { return }
        reconnectDelay = initialReconnectDelay
        openResumeConnection(silentGrace: true, forceRestartGrace: true)
    }

    private func openResumeConnection(silentGrace: Bool, forceRestartGrace: Bool, preserveGentle: Bool = false) {
        retry?.cancel()
        retry = nil
        pendingForegroundReconnect = false
        closeSocket()
        guard let saved = store.restore() else {
            fail(PairingLink.Failure.missingRelay.localizedDescription)
            return
        }
        transportKind = PairingLink.transportKind(for: saved.endpoint)
        endpointHost = saved.endpoint.host
        handshake = .resume(token: saved.token, key: saved.key, endpoint: saved.endpoint)
        let phase: ReconnectPhase
        if silentGrace {
            startReconnectGrace(targetAfterGrace: .retryingGentle, forceRestart: forceRestartGrace)
            phase = reconnectPhase
        } else if preserveGentle {
            cancelGrace()
            phase = .retryingGentle
        } else {
            cancelGrace()
            phase = .none
        }
        open(endpoint: saved.endpoint, authorization: saved.token, phase: phase)
    }

    public func pair(token: String) {
        let link: PairingLink
        do { link = try PairingLink(token, knownEndpoint: configuredEndpoint ?? store.restore()?.endpoint) }
        catch {
            if isConnected { onActionError?(error.localizedDescription) }
            else { fail(error.localizedDescription) }
            return
        }
        disconnect()
        transportKind = link.transportKind
        endpointHost = link.endpoint.host
        handshake = .pair(link)
        open(endpoint: link.endpoint, authorization: nil, phase: .none)
    }

    public func resetPairing() {
        disconnect()
        store.clear()
        transportKind = nil
        endpointHost = nil
        publishConnection(state: .idle, error: nil, reconnectPhase: .none)
    }

    public func send(_ object: [String: Any]) async throws {
        guard let socket, e2e != nil else { throw ClientError.notConnected }
        var wire = object
        if let type = object["type"] as? String, type == "rpc" || type == "extension_ui_response" {
            let payload: [String: Any] = type == "rpc" ? ["command": object["command"] as Any] : object
            guard let sealed = e2e?.seal(payload) else { throw ClientError.missingKey }
            wire = ["type": type, "id": object["id"] as Any, "sealed": sealed]
        }
        try await sendWire(wire, on: socket, triggerReconnectOnTransportError: true)
    }

    private func sendWire(_ object: [String: Any], on task: any RelaySocket, triggerReconnectOnTransportError: Bool = false) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            if triggerReconnectOnTransportError, socket === task {
                transportLost(on: task, message: error.localizedDescription)
            }
            throw error
        }
    }

    public func disconnect() {
        retry?.cancel()
        retry = nil
        cancelGrace()
        pendingForegroundReconnect = false
        closeSocket()
        publishConnection(state: .idle, error: nil, reconnectPhase: .none)
    }

    private func closeSocket() {
        cancelHeartbeat()
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        handshake = nil
        e2e = nil
    }

    private func transportLost(on task: any RelaySocket, message: String) {
        guard socket === task else { return }
        if case .pair = handshake { fail(message); return }
        closeSocket()

        guard isForeground else {
            pendingForegroundReconnect = true
            cancelGrace()
            publishConnection(state: .idle, error: nil, reconnectPhase: .silentGrace)
            return
        }

        startReconnectGrace(targetAfterGrace: .retryingGentle, forceRestart: false)
        publishConnection(state: .connecting, error: nil, reconnectPhase: reconnectPhase)

        let delay = reconnectDelay
        reconnectDelay = min(max(delay * 2, initialReconnectDelay * 4), maxReconnectDelay)
        retry?.cancel()
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.isForeground, self.socket == nil else { return }
            self.openResumeConnection(silentGrace: true, forceRestartGrace: false)
        }
    }

    private func fail(_ message: String) {
        retry?.cancel()
        retry = nil
        cancelGrace()
        pendingForegroundReconnect = false
        closeSocket()
        publishConnection(state: .error, error: message, reconnectPhase: .none)
    }

    private func open(endpoint: URL, authorization: String?, phase: ReconnectPhase) {
        var request = URLRequest(url: endpoint)
        if let token = authorization {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        publishConnection(state: .connecting, error: nil, reconnectPhase: phase)
        let task = makeSocket(request)
        socket = task
        task.resume()
        receiver = Task { [weak self] in
            guard let self, !Task.isCancelled, self.socket === task else { return }
            if case let .pair(link) = self.handshake {
                do { try await self.sendWire(["type": "pair", "token": link.code, "pub": link.key.publicKey], on: task) }
                catch {
                    if self.socket === task { self.fail(error.localizedDescription) }
                    return
                }
            }
            await self.receiveLoop(task)
        }
    }

    private func receiveLoop(_ task: any RelaySocket) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled, socket === task else { return }
                if e2e != nil { scheduleHeartbeat() }
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                await handle(object, from: task)
            } catch {
                guard !Task.isCancelled, socket === task else { return }
                transportLost(on: task, message: error.localizedDescription)
                return
            }
        }
    }

    private func finishHandshake(token: String?, on task: any RelaySocket) async {
        guard socket === task, let handshake else { return }
        guard let token, PairingLink.isHex(token, length: 64) else {
            fail("网关返回的配对凭据无效")
            return
        }
        let key: E2EKey
        switch handshake {
        case .pair(let link): key = link.key
        case .resume(let expected, let savedKey, _):
            guard token == expected else { fail("网关返回了不同的配对凭据"); return }
            key = savedKey
        }
        do { try await sendWire(["type": "pair_pub", "pub": key.publicKey], on: task) }
        catch {
            transportLost(on: task, message: error.localizedDescription)
            return
        }
        guard socket === task, !Task.isCancelled else { return }
        if case .pair(let link) = handshake, !store.save(endpoint: link.endpoint, token: token, key: key) {
            fail("无法保存配对凭据，请重新配对")
            return
        }
        self.handshake = nil
        e2e = key
        cancelGrace()
        pendingForegroundReconnect = false
        reconnectDelay = initialReconnectDelay
        publishConnection(state: .paired, error: nil, reconnectPhase: .none)
        scheduleHeartbeat()
        onPaired?(token)
    }

    func handle(_ object: [String: Any]) async {
        guard let socket else { return }
        await handle(object, from: socket)
    }

    private func handle(_ object: [String: Any], from task: any RelaySocket) async {
        guard socket === task, let type = object["type"] as? String else { return }
        if type == "paired" {
            await finishHandshake(token: object["deviceToken"] as? String, on: task)
            return
        }
        if type == "error", handshake != nil {
            fail(object["message"] as? String ?? "配对失败")
            return
        }
        guard e2e != nil else { return }
        switch type {
        case "status":
            if object["needsPairingKey"] as? Bool == true, let key = e2e {
                do { try await sendWire(["type": "pair_pub", "pub": key.publicKey], on: task) }
                catch { transportLost(on: task, message: error.localizedDescription); return }
                guard socket === task else { return }
                if state == .error || reconnectPhase != .none {
                    cancelGrace()
                    publishConnection(state: .paired, error: nil, reconnectPhase: .none)
                }
                return
            }
            if (object["state"] as? String) == "unknown" {
                startReconnectGrace(targetAfterGrace: .gatewayOfflineGentle, forceRestart: false)
                publishConnection(state: .connecting, error: nil, reconnectPhase: reconnectPhase)
            } else if let status = object["state"] as? String, ["idle", "running", "paired"].contains(status) {
                cancelGrace()
                publishConnection(state: status == "running" ? .running : .paired, error: nil, reconnectPhase: .none)
            }
        case "event":
            guard let sealed = object["sealed"] as? String, let event = e2e?.open(sealed) else { return }
            recoverFromAuthenticatedTraffic()
            onEvent?(event)
        case "rpc_response":
            guard let sealed = object["sealed"] as? String, let response = e2e?.open(sealed) else { return }
            recoverFromAuthenticatedTraffic()
            onResponse?(response)
        case "device_status":
            onDeviceStatus?(object["online"] as? Bool == true)
        case "session_list":
            onSessionList?(object["sessions"] as? [[String: Any]] ?? [])
        case "error":
            let message = object["message"] as? String ?? "连接出错"
            if message == "gateway offline" {
                startReconnectGrace(targetAfterGrace: .gatewayOfflineGentle, forceRestart: false)
                publishConnection(state: .connecting, error: nil, reconnectPhase: reconnectPhase)
            } else if message == "not paired" || message.contains("配对") || message.contains("密钥") || message.contains("加密") {
                cancelGrace()
                publishConnection(state: .error, error: message, reconnectPhase: .none)
            } else {
                onActionError?(message)
            }
        default:
            break
        }
    }

    private func recoverFromAuthenticatedTraffic() {
        guard state == .error || state == .connecting || lastError != nil || reconnectPhase != .none else { return }
        cancelGrace()
        publishConnection(state: .paired, error: nil, reconnectPhase: .none)
    }

    public enum ClientError: Error {
        case notConnected, missingKey
    }
}

@MainActor
protocol RelaySocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func ping(_ completion: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: RelaySocket {
    func ping(_ completion: @escaping @Sendable (Error?) -> Void) {
        sendPing(pongReceiveHandler: completion)
    }
}

private final class RelaySession: NSObject, URLSessionTaskDelegate {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: RelaySession(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct PairingStore {
    let read: () -> String?
    let write: (String) -> Bool
    let clear: () -> Void

    private static let recordKey = "agy-mobile.pairing.v1"
    static let keychain = PairingStore(
        read: { KeychainStore.read(recordKey) },
        write: { KeychainStore.write($0, key: recordKey) },
        clear: { KeychainStore.delete(recordKey) }
    )

    private struct Record: Codable {
        let endpoint: URL
        let token: String
        let privateKey: String
        let gatewayKey: String

        func encoded() -> String? {
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func restore() -> (endpoint: URL, token: String, key: E2EKey)? {
        guard let text = read(), let record = try? JSONDecoder().decode(Record.self, from: Data(text.utf8)),
              PairingLink.isClientEndpoint(record.endpoint), PairingLink.isHex(record.token, length: 64),
              let key = E2EKey(privateKeyBase64Url: record.privateKey, gatewayPublicKey: record.gatewayKey) else { return nil }
        return (record.endpoint, record.token, key)
    }

    func save(endpoint: URL, token: String, key: E2EKey) -> Bool {
        let record = Record(endpoint: endpoint, token: token, privateKey: key.privateRaw, gatewayKey: key.gatewayPublic)
        guard let text = record.encoded() else { return false }
        return write(text)
    }
}
