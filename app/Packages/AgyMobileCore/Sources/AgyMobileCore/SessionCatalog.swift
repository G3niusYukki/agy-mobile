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

public struct AgyWorkspaceOption: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable, Hashable {
        case pinned, recent, `default`, project
    }

    public var id: String { path }
    public let path: String
    public let name: String
    public let displayPath: String
    public let lastUsed: Date?
    public let sessionCount: Int
    public let source: Source
    public let isDefault: Bool

    public var isRecentGroup: Bool {
        source == .pinned || source == .recent || source == .default
    }

    public init(path: String, name: String? = nil, displayPath: String? = nil, lastUsed: Date? = nil,
                sessionCount: Int = 0, source: Source = .recent, isDefault: Bool = false) {
        var cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasSuffix("/") && cleaned != "/" { cleaned.removeLast() }
        self.path = cleaned
        let fallbackName = cleaned == "/" ? "/" : (cleaned as NSString).lastPathComponent
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmedName.isEmpty ? fallbackName : trimmedName
        let trimmedDisplay = displayPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayPath = trimmedDisplay.isEmpty ? cleaned : trimmedDisplay
        self.lastUsed = lastUsed
        self.sessionCount = max(0, sessionCount)
        self.source = source
        self.isDefault = isDefault
    }

    public init?(_ object: [String: Any]) {
        guard let rawPath = object["path"] as? String else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastUsed: Date?
        if let ms = (object["lastUsed"] as? NSNumber)?.doubleValue, ms.isFinite, ms > 0 {
            lastUsed = Date(timeIntervalSince1970: ms / 1_000)
        } else {
            lastUsed = nil
        }
        let source = (object["source"] as? String).flatMap(Source.init(rawValue:)) ?? .recent
        let count = (object["sessionCount"] as? NSNumber)?.intValue ?? 0
        let isDefault = object["isDefault"] as? Bool == true
        self.init(
            path: trimmed,
            name: object["name"] as? String,
            displayPath: object["displayPath"] as? String,
            lastUsed: lastUsed,
            sessionCount: count,
            source: source,
            isDefault: isDefault
        )
    }

    public static func parseList(_ objects: [[String: Any]]) -> [Self] {
        var seen = Set<String>()
        return objects.compactMap(Self.init).filter { seen.insert($0.path).inserted }
    }

    public static func fallback(fromSessions sessions: [[String: Any]], currentCwd: String? = nil, defaultCwd: String? = nil) -> [Self] {
        struct Accumulator {
            var lastUsed: Date?
            var count: Int = 0
        }
        var byPath: [String: Accumulator] = [:]
        for entry in sessions.compactMap(AgySessionEntry.init) where !entry.cwd.isEmpty {
            var acc = byPath[entry.cwd] ?? Accumulator()
            acc.count += 1
            if let mod = entry.modified, acc.lastUsed == nil || mod > acc.lastUsed! {
                acc.lastUsed = mod
            }
            byPath[entry.cwd] = acc
        }
        func clean(_ path: String?) -> String? {
            guard var value = path?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            while value.hasSuffix("/") && value != "/" { value.removeLast() }
            return value
        }
        let cleanedDefault = clean(defaultCwd)
        let cleanedCurrent = clean(currentCwd)
        var results = byPath.map { path, acc in
            Self(path: path, lastUsed: acc.lastUsed, sessionCount: acc.count, source: .recent, isDefault: path == cleanedDefault)
        }
        for path in [cleanedCurrent, cleanedDefault].compactMap({ $0 }) where byPath[path] == nil {
            results.append(Self(path: path, source: .default, isDefault: path == cleanedDefault))
        }
        return results.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source == .recent }
            let left = lhs.lastUsed ?? .distantPast
            let right = rhs.lastUsed ?? .distantPast
            if left != right { return left > right }
            if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
