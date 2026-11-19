import Foundation

public struct AgySessionEntry: Identifiable {
    public var id: String { path }
    public let path: String
    public let cwd: String
    public let title: String
    public let summary: String?
    public let modified: Date?

    public init?(_ session: [String: Any]) {
        guard let path = session["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.path = path

        var directory = session["cwd"] as? String ?? ""
        while directory.hasSuffix("/") && directory != "/" { directory.removeLast() }
        cwd = directory
        if let milliseconds = (session["mtime"] as? NSNumber)?.doubleValue, milliseconds.isFinite, milliseconds > 0 {
            modified = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            modified = nil
        }

        let rawTitle = (session["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSummary = (session["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty {
            title = rawTitle
        } else if !rawSummary.isEmpty {
            title = rawSummary
        } else if let modified {
            title = "会话 · \(modified.formatted(date: .abbreviated, time: .shortened))"
        } else {
            title = "未命名会话"
        }
        summary = rawSummary.isEmpty || rawSummary == title ? nil : rawSummary
    }

    fileprivate static func newerFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = lhs.modified ?? .distantPast
        let right = rhs.modified ?? .distantPast
        return left == right ? lhs.path < rhs.path : left > right
    }
}

public struct AgySessionFolder: Identifiable {
    public let id: String
    public let name: String
    public let parentPath: String?
    public let entries: [AgySessionEntry]

    public static func grouped(_ sessions: [[String: Any]], matching search: String = "") -> [Self] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let entries = sessions.compactMap(AgySessionEntry.init).sorted(by: AgySessionEntry.newerFirst)
            .filter { seen.insert($0.path).inserted }
        let directories = Dictionary(grouping: entries, by: \.cwd)
        let directoriesByName = Dictionary(grouping: directories.keys, by: displayName)

        let folders = directories.compactMap { cwd, entries -> Self? in
            let name = displayName(cwd)
            let matchesFolder = query.isEmpty || cwd.localizedStandardContains(query) || name.localizedStandardContains(query)
            let visible = matchesFolder ? entries : entries.filter {
                $0.title.localizedStandardContains(query) || $0.summary?.localizedStandardContains(query) == true
                    || $0.path.localizedStandardContains(query)
            }
            guard !visible.isEmpty else { return nil }
            let needsParent = !cwd.isEmpty && (directoriesByName[name]?.count ?? 0) > 1
            return Self(id: cwd, name: name, parentPath: needsParent ? (cwd as NSString).deletingLastPathComponent : nil,
                        entries: visible)
        }
        return folders.sorted { AgySessionEntry.newerFirst($0.entries[0], $1.entries[0]) }
    }

    private static func displayName(_ cwd: String) -> String {
        cwd.isEmpty ? "Antigravity 会话" : (cwd as NSString).lastPathComponent
    }
}
