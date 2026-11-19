import { spawn, execFile } from "node:child_process"
import { randomBytes } from "node:crypto"
import { existsSync, mkdirSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { readSessionHistoryStrict } from "./history.mjs"
import { defaultDataDirs, resolveWorkspaceForSession } from "./session-catalog.mjs"

const execFileAsync = promisify(execFile)
const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]/g
const EFFORT_SUFFIX_RE = /-(low|medium|high|xhigh|max)$/i

function stripAnsi(text) {
  return String(text ?? "").replace(ANSI_RE, "").replace(/\r/g, "\n")
}

export function inferProvider(modelId) {
  const id = String(modelId ?? "").toLowerCase()
  if (id.startsWith("gemini")) return "Google"
  if (id.startsWith("claude")) return "Anthropic"
  if (id.startsWith("gpt")) return "OpenAI"
  return "Antigravity"
}

export function parseAgyModelsOutput(raw) {
  const clean = stripAnsi(raw)
  const models = []
  const seen = new Set()
  for (const line of clean.split(/\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith("Fetching ") || trimmed.startsWith("Available ")) continue
    const match = /^([a-z0-9][a-z0-9._-]+)(?:\t+|\s{2,})(.+)$/i.exec(trimmed)
    if (!match) continue
    const modelId = match[1].trim()
    const displayName = match[2].trim()
    if (seen.has(modelId)) continue
    seen.add(modelId)
    models.push({
      provider: inferProvider(modelId),
      id: modelId,
      modelId,
      displayName,
    })
  }
  return models
}

function formatToolParameters(params) {
  if (!params || typeof params !== "object") return ""
  const keys = ["CommandLine", "Path", "TargetFile", "Query", "SearchPath", "DirectoryPath", "query", "url", "Description"]
  for (const key of keys) {
    if (typeof params[key] === "string" && params[key].trim()) {
      return params[key].trim()
    }
  }
  try {
    const json = JSON.stringify(params)
    return json === "{}" ? "" : json.slice(0, 240)
  } catch {
    return ""
  }
}

export class AgyRunner {
  constructor(options = {}) {
    this.agyBin = options.agyBin ?? process.env.AGY_BIN ?? "agy"
    this.defaultCwd = options.cwd ?? process.env.AGY_CWD ?? process.cwd()
    this.currentCwd = this.defaultCwd
    this.dataDirs = options.dataDirs ?? defaultDataDirs()
    this.cliDataDir = options.cliDataDir ?? join(homedir(), ".gemini", "antigravity-cli")
    this.uploadDir = options.uploadDir ?? join(homedir(), ".gemini", "agy-mobile-uploads")
    this.sandbox = options.sandbox ?? (process.env.AGY_SANDBOX === "1")
    this.skipPermissions = options.skipPermissions ?? (process.env.AGY_SKIP_PERMISSIONS === "1")
    this.extraArgs = options.extraArgs ?? (process.env.AGY_ARGS ? process.env.AGY_ARGS.split(/\s+/).filter(Boolean) : [])

    this.onEvent = options.onEvent ?? (() => {})
    this.onStatus = options.onStatus ?? (() => {})

    this.conversationId = null          // 手机侧展示的当前会话 ID（可能是桌面端会话，也可能是 CLI 会话）
    this.cliConversationId = null       // agy CLI 实际可 --conversation 续接的轨迹 ID
    this.pendingDesktopContextId = null // 若切入了桌面端会话，首次发言时自动注入近期上下文无缝续聊
    this.branchedSessions = new Map()   // desktopId -> linked cliConversationId
    this.selectedModel = options.model ?? process.env.AGY_MODEL ?? ""
    this.thinkingLevel = options.effort ?? process.env.AGY_EFFORT ?? "high"
    this.mode = options.mode ?? process.env.AGY_MODE ?? "default"

    this.modelsCache = null
    this.child = null
    this.childConfigKey = null
    this.stdoutBuffer = Buffer.alloc(0)
    this.isRunning = false
    this.pendingTurns = 0
    this.activeAssistantSteps = new Map() // step_index -> accumulated text
    this.shuttingDown = false
  }

  hasCliTrajectory(id) {
    if (!id) return false
    return existsSync(join(this.cliDataDir, "conversations", `${id}.db`))
  }

  getLinkedCliSession(desktopId) {
    if (!desktopId) return null
    return this.branchedSessions.get(desktopId) ?? null
  }

  configKey() {
    return JSON.stringify([
      this.cliConversationId ?? "",
      this.currentCwd,
      this.selectedModel,
      this.thinkingLevel,
      this.mode,
      this.sandbox,
      this.skipPermissions,
    ])
  }

  async getAvailableModels(force = false) {
    if (this.modelsCache && !force) return this.modelsCache
    try {
      const { stdout } = await execFileAsync(this.agyBin, ["models"], {
        timeout: 15_000,
        maxBuffer: 2 * 1024 * 1024,
        env: { ...process.env, NO_COLOR: "1" },
      })
      const parsed = parseAgyModelsOutput(stdout)
      if (parsed.length > 0) {
        this.modelsCache = parsed
        if (!this.selectedModel) {
          this.selectedModel = parsed[0].id
          const suffix = EFFORT_SUFFIX_RE.exec(this.selectedModel)
          if (suffix) this.thinkingLevel = suffix[1].toLowerCase()
        }
        return parsed
      }
    } catch (error) {
      process.stderr.write(`[agy] 读取模型列表失败: ${error?.message ?? error}\n`)
    }
    return this.modelsCache ?? []
  }

  getState() {
    const modelId = this.selectedModel || ""
    return {
      isStreaming: this.isRunning,
      isCompacting: false,
      pendingMessageCount: this.pendingTurns,
      sessionFile: this.conversationId,
      model: modelId ? { provider: inferProvider(modelId), id: modelId } : null,
      thinkingLevel: this.thinkingLevel,
      mode: this.mode,
      cwd: this.currentCwd,
      messageCount: this.conversationId ? undefined : 0,
    }
  }

  async setModel(modelId) {
    const target = String(modelId ?? "").trim()
    if (!target) throw new Error("模型 ID 不能为空")
    this.selectedModel = target
    const suffix = EFFORT_SUFFIX_RE.exec(target)
    if (suffix) this.thinkingLevel = suffix[1].toLowerCase()
    if (!this.isRunning) this.stopChild()
    return this.getState()
  }

  async setThinkingLevel(level) {
    const normalized = String(level ?? "").trim().toLowerCase()
    const allowed = ["low", "medium", "high", "xhigh", "max"]
    if (!allowed.includes(normalized)) {
      throw new Error(`不支持的思考强度：${level}`)
    }
    this.thinkingLevel = normalized
    // 如果当前模型存在对应强度变体（如 gemini-4-neon-high -> gemini-4-neon-xhigh），同步切换
    if (this.selectedModel && EFFORT_SUFFIX_RE.test(this.selectedModel)) {
      const candidate = this.selectedModel.replace(EFFORT_SUFFIX_RE, `-${normalized}`)
      const models = await this.getAvailableModels()
      if (models.some((m) => m.id === candidate)) {
        this.selectedModel = candidate
      }
    }
    if (!this.isRunning) this.stopChild()
    return this.getState()
  }

  async setMode(mode) {
    const normalized = String(mode ?? "").trim().toLowerCase()
    const allowed = ["default", "accept-edits", "plan"]
    if (!allowed.includes(normalized)) {
      throw new Error(`不支持的运行模式：${mode}`)
    }
    this.mode = normalized
    if (!this.isRunning) this.stopChild()
    return this.getState()
  }

  async newSession() {
    this.stopChild()
    this.conversationId = null
    this.cliConversationId = null
    this.pendingDesktopContextId = null
    this.currentCwd = this.defaultCwd
    this.isRunning = false
    this.pendingTurns = 0
    this.activeAssistantSteps.clear()
    this.onStatus("idle")
    return { cancelled: false }
  }

  async switchSession(sessionPath) {
    const id = String(sessionPath ?? "").trim()
    if (!id) throw new Error("缺少会话 ID")
    this.stopChild()
    this.conversationId = id
    if (this.hasCliTrajectory(id)) {
      this.cliConversationId = id
      this.pendingDesktopContextId = null
    } else if (this.branchedSessions.has(id)) {
      this.cliConversationId = this.branchedSessions.get(id)
      this.pendingDesktopContextId = null
    } else {
      // Antigravity 桌面端会话不存储在 antigravity-cli/conversations 下，首次回复时自动无缝续接上下文。
      this.cliConversationId = null
      this.pendingDesktopContextId = id
    }
    this.isRunning = false
    this.pendingTurns = 0
    this.activeAssistantSteps.clear()
    const workspace = await resolveWorkspaceForSession(id, this.dataDirs).catch(() => null)
    this.currentCwd = workspace && existsSync(workspace) ? workspace : this.defaultCwd
    this.onStatus("idle")
    return { cancelled: false, sessionPath: id, cwd: this.currentCwd }
  }

  buildDesktopContinuationContext(desktopId) {
    try {
      const history = readSessionHistoryStrict(desktopId, this.dataDirs)
      const recent = history.messages
        .filter((m) => (m.role === "user" || m.role === "assistant") && m.text)
        .slice(-8)
      if (recent.length === 0) return ""
      const excerpt = recent
        .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.text.slice(0, 1200)}`)
        .join("\n\n")
      return `<DESKTOP_CONTINUATION_CONTEXT>\n以下是用户在 Antigravity 桌面端该会话中的最近对话上下文，请在此基础上无缝继续回复：\n${excerpt}\n</DESKTOP_CONTINUATION_CONTEXT>\n\n`
    } catch {
      return ""
    }
  }

  stageImages(images) {
    if (!Array.isArray(images) || images.length === 0) return []
    mkdirSync(this.uploadDir, { recursive: true })
    const paths = []
    for (const image of images) {
      if (!image || typeof image.data !== "string" || !image.data) continue
      const ext = String(image.mimeType ?? "").includes("png") ? "png" : "jpg"
      const filename = `img-${Date.now()}-${randomBytes(4).toString("hex")}.${ext}`
      const fullPath = join(this.uploadDir, filename)
      writeFileSync(fullPath, Buffer.from(image.data, "base64"), { mode: 0o600 })
      paths.push(fullPath)
    }
    return paths
  }

  ensureChild() {
    const key = this.configKey()
    if (this.child && this.child.exitCode === null && this.child.signalCode === null && this.child.stdin?.writable) {
      if (this.childConfigKey === key || this.isRunning) return this.child
      this.stopChild()
    }

    const args = ["--input-format", "stream-json", "--output-format", "stream-json"]
    if (this.cliConversationId) args.push("--conversation", this.cliConversationId)
    if (this.selectedModel) args.push("--model", this.selectedModel)
    if (this.thinkingLevel && (!this.selectedModel || !EFFORT_SUFFIX_RE.test(this.selectedModel))) {
      args.push("--effort", this.thinkingLevel)
    }
    if (this.mode && this.mode !== "default") args.push("--mode", this.mode)
    if (this.sandbox) args.push("--sandbox")
    if (this.skipPermissions) args.push("--dangerously-skip-permissions")
    if (this.extraArgs.length) args.push(...this.extraArgs)

    const cwd = existsSync(this.currentCwd) ? this.currentCwd : this.defaultCwd
    const proc = spawn(this.agyBin, args, {
      cwd,
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, NO_COLOR: "1" },
    })

    this.child = proc
    this.childConfigKey = key
    this.stdoutBuffer = Buffer.alloc(0)

    proc.stderr.on("data", (chunk) => {
      const text = String(chunk).trimEnd()
      if (text) process.stderr.write(`[agy] ${text}\n`)
    })

    proc.stdout.on("data", (chunk) => {
      if (this.child !== proc) return
      this.stdoutBuffer = Buffer.concat([this.stdoutBuffer, chunk])
      for (;;) {
        const lf = this.stdoutBuffer.indexOf(0x0a)
        if (lf < 0) break
        const line = this.stdoutBuffer.subarray(0, lf).toString("utf8").replace(/\r$/, "")
        this.stdoutBuffer = this.stdoutBuffer.subarray(lf + 1)
        if (!line.trim()) continue
        let record
        try {
          record = JSON.parse(line)
        } catch {
          process.stderr.write(`[agy] 非 JSON 输出: ${line.slice(0, 200)}\n`)
          continue
        }
        this.handleAgyEvent(record)
      }
    })

    proc.on("error", (error) => {
      if (this.child !== proc) return
      process.stderr.write(`[agy] 启动失败: ${error.message}\n`)
      this.finishRunWithFailure()
    })

    proc.on("exit", (code, signal) => {
      if (this.child !== proc) return
      this.child = null
      this.childConfigKey = null
      if (this.isRunning) {
        process.stderr.write(`[agy] 进程在运行期间退出 (code=${code}, signal=${signal})\n`)
        this.finishRunWithFailure()
      }
    })

    return proc
  }

  finishRunWithFailure() {
    this.isRunning = false
    this.pendingTurns = 0
    this.activeAssistantSteps.clear()
    this.onEvent({ type: "agent_end", sessionPath: this.conversationId })
    this.onEvent({ type: "agent_settled", sessionPath: this.conversationId })
    this.onStatus("idle")
  }

  recordCliConversationId(cliId) {
    if (typeof cliId !== "string" || !cliId) return
    this.cliConversationId = cliId
    if (!this.conversationId) {
      this.conversationId = cliId
    } else if (this.conversationId !== cliId) {
      this.branchedSessions.set(this.conversationId, cliId)
    }
    this.childConfigKey = this.configKey()
  }

  handleAgyEvent(record) {
    if (!record || typeof record !== "object") return
    const eventType = record.event

    if (eventType === "init") {
      this.recordCliConversationId(record.conversation_id)
      if (typeof record.init?.model === "string" && record.init.model) {
        this.selectedModel = record.init.model
      }
      return
    }

    if (eventType === "step_update" && record.step_update) {
      const update = record.step_update
      this.recordCliConversationId(update.conversation_id)
      const sessionPath = this.conversationId
      const stepIndex = update.step_index ?? 0
      const stepType = update.step_type
      const state = update.state

      if (stepType === "user_input") {
        this.isRunning = true
        this.onStatus("running")
        this.onEvent({ type: "turn_start", sessionPath })
        this.onEvent({ type: "run_phase", phase: "thinking", sessionPath })
        return
      }

      if (stepType === "agent_response") {
        const delta = typeof update.text_delta === "string" ? update.text_delta : ""
        if (delta) {
          const prev = this.activeAssistantSteps.get(stepIndex) ?? ""
          const next = prev + delta
          this.activeAssistantSteps.set(stepIndex, next)
          this.onEvent({
            type: "message_update",
            sessionPath,
            message: { role: "assistant", content: [{ type: "text", text: next }] },
            assistantMessageEvent: { type: "text_delta", delta },
          })
        }
        if (state === "DONE") {
          const final = this.activeAssistantSteps.get(stepIndex) ?? ""
          this.activeAssistantSteps.delete(stepIndex)
          if (final) {
            this.onEvent({
              type: "message_end",
              sessionPath,
              message: { role: "assistant", content: [{ type: "text", text: final }] },
            })
          }
        }
        return
      }

      if (stepType === "tool") {
        const toolCallId = `step-${stepIndex}`
        const toolName = update.tool_name || update.tool_info?.name || "tool"
        const paramSummary = formatToolParameters(update.tool_info?.parameters)
        if (state === "ACTIVE") {
          this.onEvent({
            type: "tool_execution_start",
            sessionPath,
            toolCallId,
            toolName,
            partialResult: paramSummary ? { content: [{ type: "text", text: paramSummary }] } : undefined,
          })
        } else if (state === "DONE" || state === "ERROR") {
          const output = typeof update.tool_info?.output === "string" ? update.tool_info.output.trim() : ""
          const combined = output
            ? (paramSummary && !output.includes(paramSummary) ? `${paramSummary}\n${output}` : output)
            : paramSummary
          const durationMs = typeof update.duration_seconds === "number"
            ? Math.max(0, Math.round(update.duration_seconds * 1000))
            : undefined
          const isError = state === "ERROR" || Boolean(update.error) || Boolean(update.tool_info?.error)
          this.onEvent({
            type: "tool_execution_end",
            sessionPath,
            toolCallId,
            toolName,
            isError,
            durationMs,
            result: { content: [{ type: "text", text: combined }] },
          })
        }
        return
      }
      return
    }

    if (eventType === "result" && record.result) {
      const res = record.result
      this.recordCliConversationId(res.conversation_id)
      const sessionPath = this.conversationId
      const responseText = typeof res.response === "string" ? res.response.trimEnd() : ""
      if (responseText && this.activeAssistantSteps.size > 0) {
        this.activeAssistantSteps.clear()
        this.onEvent({
          type: "message_end",
          sessionPath,
          message: { role: "assistant", content: [{ type: "text", text: responseText }] },
        })
      } else if (res.error) {
        this.onEvent({
          type: "message_end",
          sessionPath,
          message: { role: "assistant", content: [{ type: "text", text: `执行出错：${res.error}` }] },
        })
      }
      this.pendingTurns = Math.max(0, this.pendingTurns - 1)
      if (this.pendingTurns === 0) {
        this.isRunning = false
        this.onEvent({ type: "agent_end", sessionPath })
        this.onEvent({ type: "agent_settled", sessionPath })
        this.onStatus("idle")
      }
    }
  }

  sendPrompt(command) {
    const rawText = String(command.message ?? "").trim()
    const stagedPaths = this.stageImages(command.images)
    if (!rawText && stagedPaths.length === 0) {
      throw new Error("消息内容不能为空")
    }
    let content = rawText
    if (stagedPaths.length > 0) {
      const prefix = stagedPaths.map((p) => `[已附加图片，请用 view_file 查看: ${p}]`).join("\n")
      content = content ? `${prefix}\n\n${content}` : prefix
    }
    if (this.pendingDesktopContextId) {
      const ctx = this.buildDesktopContinuationContext(this.pendingDesktopContextId)
      this.pendingDesktopContextId = null
      if (ctx) content = `${ctx}${content}`
    }

    const wasRunning = this.isRunning
    const proc = this.ensureChild()
    if (!proc.stdin?.writable) {
      throw new Error("agy 进程不可写")
    }

    this.pendingTurns += 1
    this.isRunning = true
    this.onStatus("running")
    if (!wasRunning) {
      this.onEvent({ type: "agent_start", sessionPath: this.conversationId })
      this.onEvent({ type: "run_phase", phase: "thinking", sessionPath: this.conversationId })
    }

    const line = `${JSON.stringify({ event: "user", message: { content } })}\n`
    proc.stdin.write(line)
    return { disposition: wasRunning ? "queued" : "started" }
  }

  abort() {
    const proc = this.child
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      try { proc.kill("SIGINT") } catch { /* ignore */ }
      setTimeout(() => {
        if (proc.exitCode === null && proc.signalCode === null) {
          try { proc.kill("SIGTERM") } catch { /* ignore */ }
        }
      }, 1500).unref?.()
    }
    this.child = null
    this.childConfigKey = null
    this.isRunning = false
    this.pendingTurns = 0
    this.activeAssistantSteps.clear()
    this.onEvent({ type: "agent_end", sessionPath: this.conversationId })
    this.onEvent({ type: "agent_settled", sessionPath: this.conversationId })
    this.onStatus("idle")
    return { aborted: true }
  }

  stopChild() {
    const proc = this.child
    this.child = null
    this.childConfigKey = null
    if (!proc) return
    try { proc.stdin?.end() } catch { /* ignore */ }
    setTimeout(() => {
      if (proc.exitCode === null && proc.signalCode === null) {
        try { proc.kill("SIGTERM") } catch { /* ignore */ }
      }
    }, 1000).unref?.()
  }

  shutdown() {
    this.shuttingDown = true
    this.stopChild()
  }
}
