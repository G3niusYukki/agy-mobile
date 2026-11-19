import { existsSync, readFileSync, realpathSync } from "node:fs"
import { homedir } from "node:os"
import { join, resolve } from "node:path"
import { defaultDataDirs } from "./session-catalog.mjs"

export const MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024
const DEFAULT_HISTORY_LIMIT = 80
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function extractUserRequestText(raw) {
  const text = String(raw ?? "")
  const match = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/.exec(text)
  if (match) return match[1].trim()
  return text.replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, "").trim()
}

function summarizeToolArgs(args) {
  if (!args || typeof args !== "object") return ""
  const preferredKeys = ["CommandLine", "Path", "TargetFile", "Query", "SearchPath", "DirectoryPath", "query", "url", "Description"]
  for (const key of preferredKeys) {
    if (typeof args[key] === "string" && args[key].trim()) {
      const value = args[key].trim()
      return value.length > 240 ? `${value.slice(0, 239)}…` : value
    }
  }
  return ""
}

function loadMediaAttachment(media, budget) {
  if (!media || typeof media !== "object") return null
  const mimeType = typeof media.mime_type === "string" ? media.mime_type : ""
  if (!mimeType.startsWith("image/")) return null
  const uri = typeof media.uri === "string" ? media.uri : ""
  if (!uri) return { type: "image", mimeType }
  const path = uri.startsWith("file://") ? uri.slice(7) : uri
  try {
    const resolved = realpathSync(path)
    if (!existsSync(resolved)) return { type: "image", mimeType }
    const buf = readFileSync(resolved)
    if (buf.length === 0 || buf.length > MAX_ATTACHMENT_BYTES || buf.length > budget.remaining) {
      return { type: "image", mimeType }
    }
    budget.remaining -= buf.length
    return { type: "image", mimeType, data: buf.toString("base64") }
  } catch {
    return { type: "image", mimeType }
  }
}

export function findTranscriptPath(conversationId, dataDirs = defaultDataDirs()) {
  if (!UUID_RE.test(String(conversationId ?? ""))) {
    throw new Error("无效的会话 ID")
  }
  for (const dir of dataDirs) {
    const logsDir = join(dir, "brain", conversationId, ".system_generated", "logs")
    const full = join(logsDir, "transcript_full.jsonl")
    if (existsSync(full)) return full
    const compact = join(logsDir, "transcript.jsonl")
    if (existsSync(compact)) return compact
  }
  return null
}

export function readSessionHistoryStrict(conversationId, dataDirs = defaultDataDirs(), options = {}) {
  const id = String(conversationId ?? "").trim()
  if (!UUID_RE.test(id)) {
    throw new Error("无效的会话 ID")
  }
  const transcriptPath = findTranscriptPath(id, dataDirs)
  if (!transcriptPath) {
    // 刚创建的新会话或尚无本地日志的会话，检查是否在已知目录存在
    const hasConversation = dataDirs.some((dir) =>
      existsSync(join(dir, "conversations", `${id}.db`)) || existsSync(join(dir, "brain", id))
    )
    if (hasConversation) {
      return { sessionPath: id, messages: [], hasEarlierMessages: false }
    }
    throw new Error("未找到该会话的本地记录")
  }

  const lines = readFileSync(resolve(transcriptPath), "utf8").split(/\r?\n/)
  const steps = []
  for (const line of lines) {
    if (!line.trim()) continue
    try {
      const obj = JSON.parse(line)
      if (obj && typeof obj === "object") steps.push(obj)
    } catch {
      // 忽略损坏单行
    }
  }

  // 构建标准消息序列：USER_INPUT → user，PLANNER_RESPONSE → assistant + pending tool_calls，GENERIC → tool output
  const allMessages = []
  const pendingTools = []

  for (const step of steps) {
    const stepId = `step-${step.step_index ?? allMessages.length}`
    if (step.type === "USER_INPUT" && step.source !== "SYSTEM") {
      const text = extractUserRequestText(step.content)
      const media = Array.isArray(step.media) ? step.media : []
      if (!text && media.length === 0) continue
      allMessages.push({
        id: stepId,
        role: "user",
        text,
        _rawMedia: media,
      })
      continue
    }

    if (step.type === "PLANNER_RESPONSE") {
      const text = typeof step.content === "string" ? step.content.trim() : ""
      if (text) {
        allMessages.push({
          id: `${stepId}-text`,
          role: "assistant",
          text,
        })
      }
      if (Array.isArray(step.tool_calls)) {
        step.tool_calls.forEach((call, index) => {
          const toolName = String(call?.name ?? "tool")
          const callId = `${stepId}-call-${index}`
          const argSummary = summarizeToolArgs(call?.arguments)
          const item = {
            id: callId,
            role: "tool",
            toolTitle: toolName,
            toolCallId: callId,
            text: argSummary,
            isError: false,
          }
          allMessages.push(item)
          pendingTools.push(item)
        })
      }
      continue
    }

    if (step.type === "GENERIC" && pendingTools.length > 0) {
      const target = pendingTools.shift()
      const content = typeof step.content === "string" ? step.content.trim() : ""
      if (content) {
        target.text = target.text && !content.includes(target.text)
          ? `${target.text}\n${content}`
          : content
      }
      if (step.status === "ERROR") target.isError = true
    }
  }

  let startIndex = Math.max(0, allMessages.length - DEFAULT_HISTORY_LIMIT)
  if (typeof options.anchorId === "string" && options.anchorId) {
    const anchorIndex = allMessages.findIndex((m) => m.id === options.anchorId)
    if (anchorIndex >= 0 && anchorIndex < startIndex) startIndex = anchorIndex
  }
  const hasEarlierMessages = startIndex > 0
  const slice = allMessages.slice(startIndex)

  // 从最新消息倒序分配 2 MiB 图片附件预算
  const budget = { remaining: MAX_ATTACHMENT_BYTES }
  const projected = new Array(slice.length)
  for (let i = slice.length - 1; i >= 0; i--) {
    const item = slice[i]
    const out = {
      id: item.id,
      role: item.role,
      text: item.text ?? "",
    }
    if (item.toolTitle) out.toolTitle = item.toolTitle
    if (item.toolCallId) out.toolCallId = item.toolCallId
    if (item.isError) out.isError = true
    if (Array.isArray(item._rawMedia) && item._rawMedia.length > 0) {
      const attachments = item._rawMedia.map((m) => loadMediaAttachment(m, budget)).filter(Boolean)
      if (attachments.length > 0) out.attachments = attachments
    }
    projected[i] = out
  }

  return {
    sessionPath: id,
    messages: projected,
    hasEarlierMessages,
  }
}

export function getHomeDir() {
  return homedir()
}
