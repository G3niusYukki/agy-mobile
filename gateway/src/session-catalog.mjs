import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const MAX_SESSIONS = 50
const MAX_WORKSPACES = 30
const MAX_RECENT_WORKSPACES = 24
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const IGNORED_SCAN_DIRS = new Set([
  "Library", "Applications", "Desktop", "Documents", "Downloads",
  "Movies", "Music", "Pictures", "Public", "node_modules", "venv",
])

let sqliteModulePromise = null
async function getSQLite() {
  if (!sqliteModulePromise) {
    sqliteModulePromise = import("node:sqlite").catch(() => null)
  }
  return sqliteModulePromise
}

export function defaultDataDirs() {
  const home = homedir()
  const dirs = [join(home, ".gemini", "antigravity-cli")]
  if (process.env.AGY_INCLUDE_DESKTOP_SESSIONS !== "0") {
    dirs.push(join(home, ".gemini", "antigravity"))
  }
  return dirs
}

function parseWorkspaceURI(raw) {
  if (!raw || typeof raw !== "string") return ""
  try {
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      for (const uri of parsed) {
        if (typeof uri !== "string" || !uri) continue
        if (uri.startsWith("file://")) {
          try { return fileURLToPath(uri) } catch { return uri.slice(7) }
        }
        return uri
      }
    }
  } catch {
    if (raw.startsWith("file://")) {
      try { return fileURLToPath(raw) } catch { return raw.slice(7) }
    }
  }
  return ""
}

function parseTimestamp(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value !== "string" || !value.trim()) return 0
  const normalized = value.trim().replace(" ", "T")
  const ms = Date.parse(normalized)
  return Number.isFinite(ms) ? ms : 0
}

function cleanSnippet(value, limit = 160) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim()
  if (!text) return ""
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text
}

async function readDBSummaries(dir) {
  const dbPath = join(dir, "conversation_summaries.db")
  if (!existsSync(dbPath)) return []
  const sqlite = await getSQLite()
  if (!sqlite?.DatabaseSync) return []
  let db
  try {
    db = new sqlite.DatabaseSync(dbPath, { readOnly: true })
    const rows = db.prepare(`
      SELECT conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status
      FROM conversation_summaries
      WHERE COALESCE(parent_conversation_id, '') = ''
        AND COALESCE(nesting_depth, 0) = 0
        AND COALESCE(killed, 0) = 0
        AND COALESCE(step_count, 0) > 0
      ORDER BY last_modified_time DESC
      LIMIT ?
    `).all(MAX_SESSIONS)
    return rows.map((row) => ({
      id: String(row.conversation_id ?? ""),
      title: cleanSnippet(row.title, 80),
      summary: cleanSnippet(row.preview, 160),
      cwd: parseWorkspaceURI(row.workspace_uris),
      mtime: parseTimestamp(row.last_modified_time),
      running: String(row.status ?? "").includes("RUNNING"),
      dataDir: dir,
    })).filter((entry) => UUID_RE.test(entry.id))
  } catch {
    return []
  } finally {
    try { db?.close() } catch { /* ignore */ }
  }
}

function scanBrainFallback(dir) {
  const brainDir = join(dir, "brain")
  if (!existsSync(brainDir)) return []
  const entries = []
  try {
    for (const name of readdirSync(brainDir)) {
      if (!UUID_RE.test(name)) continue
      const fullLog = join(brainDir, name, ".system_generated", "logs", "transcript_full.jsonl")
      const compactLog = join(brainDir, name, ".system_generated", "logs", "transcript.jsonl")
      const target = existsSync(fullLog) ? fullLog : (existsSync(compactLog) ? compactLog : null)
      if (!target) continue
      const st = statSync(target)
      entries.push({
        id: name,
        title: "",
        summary: "",
        cwd: "",
        mtime: Math.round(st.mtimeMs),
        running: false,
        dataDir: dir,
      })
    }
  } catch {
    // 忽略不可读目录
  }
  return entries
}

export async function listSessionCatalog(dataDirs = defaultDataDirs()) {
  const byId = new Map()
  for (const dir of dataDirs) {
    const dbRows = await readDBSummaries(dir)
    const rows = dbRows.length > 0 ? dbRows : scanBrainFallback(dir)
    for (const row of rows) {
      const prev = byId.get(row.id)
      if (!prev || row.mtime > prev.mtime || (!prev.title && row.title) || (!prev.cwd && row.cwd)) {
        byId.set(row.id, {
          path: row.id,
          cwd: row.cwd || prev?.cwd || "",
          mtime: Math.max(row.mtime, prev?.mtime || 0),
          title: row.title || prev?.title || row.summary || "",
          summary: row.summary && row.summary !== row.title ? row.summary : (prev?.summary || ""),
        })
      }
    }
  }
  return [...byId.values()]
    .sort((a, b) => (b.mtime - a.mtime) || a.path.localeCompare(b.path))
    .slice(0, MAX_SESSIONS)
}

export async function resolveWorkspaceForSession(conversationId, dataDirs = defaultDataDirs()) {
  if (!UUID_RE.test(String(conversationId ?? ""))) return null
  const list = await listSessionCatalog(dataDirs)
  const hit = list.find((item) => item.path === conversationId)
  return hit?.cwd && existsSync(hit.cwd) ? hit.cwd : null
}

export function normalizeWorkspacePath(raw, home = homedir()) {
  let value = String(raw ?? "").trim()
  if (!value) return ""
  if (value === "~") value = home
  else if (value.startsWith("~/")) value = join(home, value.slice(2))
  const resolved = resolve(value)
  return resolved.length > 1 ? resolved.replace(/\/+$/, "") : resolved
}

export function formatDisplayPath(fullPath, home = homedir()) {
  if (!fullPath) return ""
  const normalizedHome = normalizeWorkspacePath(home, home)
  if (fullPath === normalizedHome) return "~"
  if (fullPath.startsWith(`${normalizedHome}/`)) return `~/${fullPath.slice(normalizedHome.length + 1)}`
  return fullPath
}

function isExistingDirectory(path) {
  if (!path) return false
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

export function defaultRecentWorkspacesFile() {
  return process.env.AGY_RECENT_WORKSPACES_PATH ?? join(homedir(), ".gemini", "agy-mobile-workspaces.json")
}

export function readRecentWorkspaces(filePath = defaultRecentWorkspacesFile()) {
  if (!filePath || !existsSync(filePath)) return []
  try {
    const parsed = JSON.parse(readFileSync(filePath, "utf8"))
    const list = Array.isArray(parsed) ? parsed : []
    return list
      .map((item) => ({
        path: normalizeWorkspacePath(item?.path),
        lastUsed: typeof item?.lastUsed === "number" && Number.isFinite(item.lastUsed) ? item.lastUsed : 0,
      }))
      .filter((item) => item.path)
  } catch {
    return []
  }
}

export function recordRecentWorkspace(workspacePath, filePath = defaultRecentWorkspacesFile()) {
  const normalized = normalizeWorkspacePath(workspacePath)
  if (!normalized || !isExistingDirectory(normalized) || !filePath) return
  try {
    const existing = readRecentWorkspaces(filePath).filter((item) => item.path !== normalized)
    const updated = [{ path: normalized, lastUsed: Date.now() }, ...existing].slice(0, MAX_RECENT_WORKSPACES)
    mkdirSync(dirname(filePath), { recursive: true })
    writeFileSync(filePath, JSON.stringify(updated, null, 2), { mode: 0o600 })
    chmodSync(filePath, 0o600)
  } catch {
    // 忽略只读或无权限写入场景
  }
}

function parseAllWorkspaceURIs(raw) {
  if (!raw || typeof raw !== "string") return []
  const uris = []
  try {
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      for (const item of parsed) {
        if (typeof item === "string" && item.trim()) uris.push(item.trim())
      }
    } else if (typeof parsed === "string" && parsed.trim()) {
      uris.push(parsed.trim())
    }
  } catch {
    if (raw.trim()) uris.push(raw.trim())
  }
  const paths = []
  for (const uri of uris) {
    if (uri.startsWith("file://")) {
      try { paths.push(normalizeWorkspacePath(fileURLToPath(uri))) } catch { paths.push(normalizeWorkspacePath(uri.slice(7))) }
    } else if (uri.startsWith("/") || uri.startsWith("~")) {
      paths.push(normalizeWorkspacePath(uri))
    }
  }
  return paths.filter(Boolean)
}

async function readDBWorkspaces(dir) {
  const dbPath = join(dir, "conversation_summaries.db")
  if (!existsSync(dbPath)) return []
  const sqlite = await getSQLite()
  if (!sqlite?.DatabaseSync) return []
  let db
  try {
    db = new sqlite.DatabaseSync(dbPath, { readOnly: true })
    const rows = db.prepare(`
      SELECT workspace_uris, MAX(last_modified_time) AS last_mod, COUNT(*) AS cnt
      FROM conversation_summaries
      WHERE COALESCE(killed, 0) = 0
        AND COALESCE(workspace_uris, '') != ''
      GROUP BY workspace_uris
      ORDER BY last_mod DESC
      LIMIT 60
    `).all()
    const results = []
    for (const row of rows) {
      const lastUsed = parseTimestamp(row.last_mod)
      const sessionCount = Number(row.cnt) || 0
      for (const path of parseAllWorkspaceURIs(row.workspace_uris)) {
        results.push({ path, lastUsed, sessionCount })
      }
    }
    return results
  } catch {
    return []
  } finally {
    try { db?.close() } catch { /* ignore */ }
  }
}

function parseWorkspaceListEnv(raw) {
  if (!raw || typeof raw !== "string") return []
  const trimmed = raw.trim()
  if (!trimmed) return []
  if (trimmed.startsWith("[")) {
    try {
      const parsed = JSON.parse(trimmed)
      if (Array.isArray(parsed)) return parsed.map((v) => normalizeWorkspacePath(v)).filter(Boolean)
    } catch { /* fall through */ }
  }
  return trimmed.split(/[:,\n]/).map((v) => normalizeWorkspacePath(v)).filter(Boolean)
}

function defaultScanRoots() {
  if (process.env.AGY_SCAN_WORKSPACE_ROOTS === "0") return []
  if (process.env.AGY_WORKSPACE_ROOTS) return parseWorkspaceListEnv(process.env.AGY_WORKSPACE_ROOTS)
  const home = homedir()
  return [home, join(home, "projects")]
}

function scanProjectDirectories(roots) {
  const discovered = []
  for (const rawRoot of roots ?? []) {
    const root = normalizeWorkspacePath(rawRoot)
    if (!isExistingDirectory(root)) continue
    let entries = []
    try {
      entries = readdirSync(root, { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      if (entry.name.startsWith(".") || IGNORED_SCAN_DIRS.has(entry.name)) continue
      const fullPath = join(root, entry.name)
      if (!existsSync(join(fullPath, ".git"))) continue
      let mtime = 0
      try {
        mtime = Math.round(statSync(fullPath).mtimeMs)
      } catch { /* ignore */ }
      discovered.push({ path: normalizeWorkspacePath(fullPath), lastUsed: mtime })
    }
  }
  return discovered
}

const SOURCE_RANK = { pinned: 0, recent: 1, default: 2, project: 3 }

export async function listWorkspaces(options = {}) {
  const dataDirs = options.dataDirs ?? defaultDataDirs()
  const home = options.home ?? homedir()
  const normalizedDefault = normalizeWorkspacePath(options.defaultCwd ?? "", home)
  const normalizedCurrent = normalizeWorkspacePath(options.currentCwd ?? "", home)
  const maxWorkspaces = options.maxWorkspaces ?? MAX_WORKSPACES
  const recentFile = options.recentWorkspacesFile === undefined ? defaultRecentWorkspacesFile() : options.recentWorkspacesFile
  const extraWorkspaces = options.extraWorkspaces ?? parseWorkspaceListEnv(process.env.AGY_WORKSPACES ?? "")
  const scanRoots = options.scanRoots === undefined ? defaultScanRoots() : options.scanRoots

  const byPath = new Map()

  function upsert(rawPath, patch = {}) {
    const path = normalizeWorkspacePath(rawPath, home)
    if (!path || !isExistingDirectory(path)) return
    const prev = byPath.get(path)
    const nextSource = prev
      ? (SOURCE_RANK[patch.source ?? "project"] < SOURCE_RANK[prev.source] ? patch.source : prev.source)
      : (patch.source ?? "project")
    byPath.set(path, {
      path,
      name: path === "/" ? "/" : basename(path),
      displayPath: formatDisplayPath(path, home),
      lastUsed: Math.max(prev?.lastUsed ?? 0, patch.lastUsed ?? 0),
      sessionCount: (prev?.sessionCount ?? 0) + (patch.sessionCount ?? 0),
      source: nextSource,
      isDefault: path === normalizedDefault,
      pinOrder: prev?.pinOrder ?? patch.pinOrder ?? Number.MAX_SAFE_INTEGER,
    })
  }

  // 1. 显式固定的工作区（AGY_WORKSPACES）
  extraWorkspaces.forEach((path, index) => {
    upsert(path, { source: "pinned", pinOrder: index })
  })

  // 2. Antigravity 历史数据库中的最近工作区
  for (const dir of dataDirs) {
    const rows = await readDBWorkspaces(dir)
    for (const row of rows) {
      upsert(row.path, { source: "recent", lastUsed: row.lastUsed, sessionCount: row.sessionCount })
    }
  }

  // 3. 手机端近期选择过的工作区
  if (recentFile) {
    for (const item of readRecentWorkspaces(recentFile)) {
      upsert(item.path, { source: "recent", lastUsed: item.lastUsed })
    }
  }

  // 4. 当前活跃目录与网关默认目录
  if (normalizedCurrent) upsert(normalizedCurrent, { source: "default" })
  if (normalizedDefault) upsert(normalizedDefault, { source: "default" })

  // 5. 本机常见 Git 项目目录（仅扫描 1 层）
  for (const proj of scanProjectDirectories(scanRoots)) {
    upsert(proj.path, { source: "project", lastUsed: proj.lastUsed })
  }

  return [...byPath.values()]
    .sort((a, b) => {
      const rankDiff = (SOURCE_RANK[a.source] ?? 9) - (SOURCE_RANK[b.source] ?? 9)
      if (rankDiff !== 0) return rankDiff
      if (a.source === "pinned") return a.pinOrder - b.pinOrder
      if (b.lastUsed !== a.lastUsed) return b.lastUsed - a.lastUsed
      if (b.sessionCount !== a.sessionCount) return b.sessionCount - a.sessionCount
      if (a.isDefault !== b.isDefault) return a.isDefault ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    .slice(0, maxWorkspaces)
    .map(({ pinOrder: _pinOrder, ...entry }) => entry)
}
