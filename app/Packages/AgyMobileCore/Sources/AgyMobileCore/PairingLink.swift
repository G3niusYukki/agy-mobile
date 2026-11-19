import Foundation
import Network

public enum ConnectionTransportKind: String, Sendable, Equatable {
    case direct
    case relay

    public var title: String {
        switch self {
        case .direct: return "局域网 / Tailscale 直连"
        case .relay: return "公网中继"
        }
    }

    public var shortTitle: String {
        switch self {
        case .direct: return "直连"
        case .relay: return "中继"
        }
    }
}

/// 支持双模配对链接：
/// 1. 公网自托管 Relay：`https://relay.example.com/agy/pair#<32hex>.<pub>` -> `wss://.../agy/client`
/// 2. 局域网 / Tailscale 直连：`http://<私有IP或.local/.ts.net>:<port>/agy/pair#<32hex>.<pub>` -> `ws://.../agy/client`
public struct PairingLink {
    public let endpoint: URL
    public let code: String
    public let key: E2EKey
    public let transportKind: ConnectionTransportKind

    public init(_ input: String, knownEndpoint: URL? = nil) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment: String
        if input.contains("#") {
            if var url = Self.components(input, scheme: "https", path: "/agy/pair"),
               let value = url.percentEncodedFragment {
                fragment = value
                url.scheme = "wss"
                url.path = "/agy/client"
                url.fragment = nil
                guard let target = url.url else { throw Failure.invalidLink }
                endpoint = target
                transportKind = Self.isLocalOrPrivateHost(url.encodedHost ?? "") ? .direct : .relay
            } else if var url = Self.components(input, scheme: "http", path: "/agy/pair"),
                      Self.isLocalOrPrivateHost(url.encodedHost ?? ""),
                      let value = url.percentEncodedFragment {
                fragment = value
                url.scheme = "ws"
                url.path = "/agy/client"
                url.fragment = nil
                guard let target = url.url else { throw Failure.invalidLink }
                endpoint = target
                transportKind = .direct
            } else {
                throw Failure.invalidLink
            }
        } else {
            guard let knownEndpoint, Self.isClientEndpoint(knownEndpoint) else { throw Failure.missingRelay }
            endpoint = knownEndpoint
            transportKind = Self.transportKind(for: knownEndpoint)
            fragment = input
        }
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isHex(parts[0], length: 32),
              let key = E2EKey(gatewayPublicKey: String(parts[1])) else { throw Failure.invalidCode }
        code = parts[0].lowercased()
        self.key = key
    }

    public static func transportKind(for endpoint: URL) -> ConnectionTransportKind {
        let host = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.encodedHost ?? endpoint.host ?? ""
        if endpoint.scheme?.lowercased() == "ws" || isLocalOrPrivateHost(host) {
            return .direct
        }
        return .relay
    }

    public static func isClientEndpoint(_ url: URL) -> Bool {
        if let parts = components(url.absoluteString, scheme: "wss", path: "/agy/client") {
            return parts.fragment == nil
        }
        if let parts = components(url.absoluteString, scheme: "ws", path: "/agy/client"),
           isLocalOrPrivateHost(parts.encodedHost ?? "") {
            return parts.fragment == nil
        }
        return false
    }

    /// 仅允许对私有局域网、Tailscale CGNAT (100.64.0.0/10)、本机及 `.local`/`.ts.net` 使用明文传输层（载荷仍全程 AES-256-GCM 端到端加密）。
    public static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") {
            return true
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            let v6 = String(host.dropFirst().dropLast())
            if v6 == "::1" || v6.hasPrefix("fc") || v6.hasPrefix("fd") || v6.hasPrefix("fe80:") {
                return true
            }
            return false
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 10 || a == 127 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 100 && (64...127).contains(b) { return true } // Tailscale CGNAT
        return false
    }

    public static func isHex<S: StringProtocol>(_ value: S, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    private static func components(_ input: String, scheme: String, path: String) -> URLComponents? {
        guard let parts = URLComponents(string: input, encodingInvalidCharacters: false),
              parts.scheme?.lowercased() == scheme, parts.percentEncodedPath == path,
              parts.user == nil, parts.password == nil, parts.query == nil,
              let host = parts.encodedHost, !host.isEmpty else { return nil }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), !host.contains("%"), IPv6Address(String(host.dropFirst().dropLast())) != nil else { return nil }
        } else {
            let label = #"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"#
            guard host.utf8.count <= 254, host.range(of: "^\(label)(?:\\.\(label))*\\.?$", options: .regularExpression) != nil else { return nil }
        }
        let authority = input.dropFirst(scheme.count + 3).prefix { $0 != "/" }
        let port = parts.port
        guard port.map({ (1...65535).contains($0) }) != false,
              authority == host + (port.map { ":\($0)" } ?? "") else { return nil }
        return parts
    }

    public enum Failure: LocalizedError {
        case invalidLink, invalidCode, missingRelay
        public var errorDescription: String? {
            switch self {
            case .invalidLink: return "配对链接无效，请扫描或粘贴网关生成的完整配对链接（支持 HTTPS 中继或局域网/Tailscale 直连）"
            case .invalidCode: return "配对码或网关公钥无效，请重新扫描配对链接"
            case .missingRelay: return "尚未指定连接地址，请扫描或粘贴网关生成的完整配对链接"
            }
        }
    }
}
