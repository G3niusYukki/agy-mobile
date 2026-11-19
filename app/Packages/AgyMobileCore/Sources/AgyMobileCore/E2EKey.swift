import Foundation
import CryptoKit

/// 端到端加密（X25519 + HKDF-SHA256 + AES-256-GCM）。
/// 无论直连局域网/Tailscale 还是经过公网 Relay，所有业务载荷均以密文传输。
public struct E2EKey: Sendable {
    private static let salt = Data("agy-mobile-e2e-v1".utf8)
    private static let info = Data("agy-mobile".utf8)

    private let symmetric: SymmetricKey
    public let publicKey: String
    public let privateRaw: String
    public let gatewayPublic: String

    public init?(gatewayPublicKey: String) {
        guard let peerRaw = Data(base64UrlEncoded: gatewayPublicKey), peerRaw.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerRaw) else { return nil }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        self.symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Self.salt, sharedInfo: Self.info, outputByteCount: 32
        )
        self.publicKey = priv.publicKey.rawRepresentation.base64UrlEncoded
        self.privateRaw = priv.rawRepresentation.base64UrlEncoded
        self.gatewayPublic = peerRaw.base64UrlEncoded
    }

    public init?(privateKeyBase64Url: String, gatewayPublicKey: String) {
        guard let privRaw = Data(base64UrlEncoded: privateKeyBase64Url), privRaw.count == 32,
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privRaw),
              let peerRaw = Data(base64UrlEncoded: gatewayPublicKey), peerRaw.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerRaw),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        self.symmetric = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Self.salt, sharedInfo: Self.info, outputByteCount: 32
        )
        self.publicKey = priv.publicKey.rawRepresentation.base64UrlEncoded
        self.privateRaw = privRaw.base64UrlEncoded
        self.gatewayPublic = peerRaw.base64UrlEncoded
    }

    public func seal(_ object: [String: Any]) -> String? {
        guard let plain = try? JSONSerialization.data(withJSONObject: object),
              let box = try? AES.GCM.seal(plain, using: symmetric),
              let combined = box.combined else { return nil }
        return combined.base64UrlEncoded
    }

    public func open(_ sealed: String) -> [String: Any]? {
        guard let blob = Data(base64UrlEncoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: symmetric),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return nil }
        return obj
    }
}

public extension Data {
    var base64UrlEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64UrlEncoded: String) {
        var s = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: s)
    }
}
