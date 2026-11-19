import { existsSync, readdirSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const MAX_SESSIONS = 50
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

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
