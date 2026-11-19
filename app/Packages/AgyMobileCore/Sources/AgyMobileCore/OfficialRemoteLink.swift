import Foundation

/// 解析并校验 Antigravity 桌面端（Settings → Remote Control）生成的官方远程控制二维码链接。
/// 支持两种合法形式：
/// 1. `https://antigravity.google.com/r/<device-id>`（或 `antigravity.google`）
/// 2. `https://accounts.google.com/AccountChooser?...&continue=https%3A%2F%2Fantigravity.google.com%2Fr%2F<device-id>`
public struct OfficialRemoteLink: Equatable, Codable, Sendable {
    public let launchURL: URL
    public let targetURL: URL
    public let deviceID: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return nil }

        if Self.isOfficialRemoteHost(host), let id = Self.extractDeviceID(from: url) {
            self.launchURL = url
            self.targetURL = url
            self.deviceID = id
            return
        }

        if host == "accounts.google.com",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let continueValue = components.queryItems?.first(where: { $0.name == "continue" })?.value,
           let target = URL(string: continueValue),
           target.scheme?.lowercased() == "https",
           let targetHost = target.host?.lowercased(),
           Self.isOfficialRemoteHost(targetHost),
           let id = Self.extractDeviceID(from: target) {
            self.launchURL = url
            self.targetURL = target
            self.deviceID = id
            return
        }

        return nil
    }

    private static func isOfficialRemoteHost(_ host: String) -> Bool {
        host == "antigravity.google.com" || host == "antigravity.google"
    }

    private static func extractDeviceID(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "r" else { return nil }
        let id = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 128,
              id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
}
