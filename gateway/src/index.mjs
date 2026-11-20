// Antigravity Mobile Mac 网关：托管 agy CLI（stream-json），
// 同时支持「局域网 / Tailscale 零部署直连」与「自托管 Relay 公网穿透」，业务载荷全程 E2E 加密。
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"
import { env } from "node:process"
import QRCode from "qrcode"
import WebSocket from "ws"
import { AgyRunner } from "./agy-runner.mjs"
import { createE2EChannel, gatewayPublicKey } from "./crypto.mjs"
import { MAX_ATTACHMENT_BYTES, readSessionHistoryStrict } from "./history.mjs"
import { createLocalDirectServer, discoverLocalAddresses } from "./local-server.mjs"
import { defaultDataDirs, listSessionCatalog, listWorkspaces } from "./session-catalog.mjs"

try {
  for (const line of readFileSync(new URL("../.env", import.meta.url), "utf8").split(/\r?\n/)) {
    const match = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line.trim())
    if (match && env[match[1]] === undefined) env[match[1]] = match[2]
  }
} catch {
  // 无 .env 时使用进程环境变量
}

const RELAY_URL = env.RELAY_URL ?? ""
const GATEWAY_TOKEN = env.GATEWAY_TOKEN ?? ""
const PAIR_BASE = env.PAIR_BASE ?? ""
const ENABLE_LOCAL = env.ENABLE_LOCAL !== "0"
const LOCAL_HOST = env.LOCAL_HOST ?? "0.0.0.0"
const LOCAL_PORT = Number(env.LOCAL_PORT ?? 8790)
const DATA_DIRS = defaultDataDirs()
const RECEIPT_LIMIT = 128
const MAX_RECEIPT_ID_LENGTH = 128

if (RELAY_URL) {
  if (!GATEWAY_TOKEN) {
    console.error("配置了 RELAY_URL 但缺少 GATEWAY_TOKEN")
    process.exit(1)
  }
  let pairURL
  try { pairURL = new URL(PAIR_BASE) } catch { /* validated below */ }
  if (!pairURL || pairURL.protocol !== "https:" || pairURL.pathname !== "/agy/pair" ||
      pairURL.username || pairURL.password || pairURL.search || pairURL.hash) {
    console.error("请将 PAIR_BASE 设置为中继的公开 HTTPS 配对地址，例如 https://relay.example.com/agy/pair")
    process.exit(1)
  }
}

if (!ENABLE_LOCAL && !RELAY_URL) {
  console.error("请至少启用本地直连（ENABLE_LOCAL=1）或配置 RELAY_URL")
  process.exit(1)
}

const channels = new Map() // transportName -> { e2e, send, promptReceipts, phonePublicKey }
let shuttingDown = false

function broadcastSealed(type, payload) {
  for (const ch of channels.values()) {
    if (!ch.e2e.hasSessionKey()) continue
    const sealed = ch.e2e.seal(payload)
    if (sealed) ch.send({ type, sealed })
  }
}

function broadcastRaw(obj) {
  for (const ch of channels.values()) ch.send(obj)
}

const runner = new AgyRunner({
  dataDirs: DATA_DIRS,
  onEvent(event) {
    broadcastSealed("event", event)
  },
  onStatus(state) {
    broadcastRaw({ type: "status", state })
  },
})

function rememberPromptReceipt(ch, id, record) {
  if (typeof id !== "string" || id.length > MAX_RECEIPT_ID_LENGTH) return
  const receipt = { id, success: record.success }
  if (["started", "queued", "handled"].includes(record.data?.disposition)) {
    receipt.data = { disposition: record.data.disposition }
  }
  if (!record.success && typeof record.error === "string") receipt.error = record.error.slice(0, 2048)
  ch.promptReceipts.delete(id)
  ch.promptReceipts.set(id, receipt)
  if (ch.promptReceipts.size > RECEIPT_LIMIT) ch.promptReceipts.delete(ch.promptReceipts.keys().next().value)
}

function sendReply(ch, response) {
  const sealed = ch.e2e.seal(response)
  if (sealed) ch.send({ type: "rpc_response", sealed })
}

async function getWorkspaceList() {
  return listWorkspaces({
    dataDirs: DATA_DIRS,
    defaultCwd: runner.defaultCwd,
    currentCwd: runner.currentCwd,
    recentWorkspacesFile: runner.recentWorkspacesFile,
  })
}

async function handleRPC(ch, command, fallbackId) {
  const id = command?.id ?? fallbackId ?? null
  const type = command?.type
  try {
    if (type === "session_catalog") {
      const [sessions, workspaces] = await Promise.all([
        listSessionCatalog(DATA_DIRS),
        getWorkspaceList(),
      ])
      sendReply(ch, {
        id,
        success: true,
        data: {
          sessions,
          workspaces,
          defaultCwd: runner.defaultCwd,
          currentCwd: runner.currentCwd,
        },
      })
      return
    }
    if (type === "list_workspaces") {
      const workspaces = await getWorkspaceList()
      sendReply(ch, {
        id,
        success: true,
        data: {
          workspaces,
          defaultCwd: runner.defaultCwd,
          currentCwd: runner.currentCwd,
        },
      })
      return
    }
    if (type === "session_history") {
      const data = readSessionHistoryStrict(command.sessionPath, DATA_DIRS, { anchorId: command.anchorId })
      const linkedCliId = runner.getLinkedCliSession(command.sessionPath)
      if (linkedCliId && linkedCliId !== command.sessionPath) {
        try {
          const branchHistory = readSessionHistoryStrict(linkedCliId, DATA_DIRS)
          if (branchHistory.messages.length > 0) {
            const appended = branchHistory.messages.map((m) => ({
              ...m,
              id: `branch-${m.id}`,
              toolCallId: m.toolCallId ? `branch-${m.toolCallId}` : undefined,
            }))
            data.messages = [...data.messages, ...appended]
          }
        } catch {
          // CLI 分支刚启动尚未落盘日志时忽略
        }
      }
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "get_available_models") {
      const models = await runner.getAvailableModels()
      sendReply(ch, { id, success: true, data: { models } })
      return
    }
    if (type === "get_state") {
      await runner.getAvailableModels()
      const state = { ...runner.getState(), sessionBarrier: true }
      if (typeof command.afterSessionChangeId === "string") state.sessionBarrierId = command.afterSessionChangeId
      if (typeof command.afterSettingChangeId === "string") state.settingBarrierId = command.afterSettingChangeId
      if (Array.isArray(command.promptReceiptIds)) {
        const ids = [...new Set(command.promptReceiptIds.slice(0, 32).filter((v) => typeof v === "string" && v.length <= MAX_RECEIPT_ID_LENGTH))]
        state.promptReceipts = ids.filter((rid) => ch.promptReceipts.has(rid)).map((rid) => ch.promptReceipts.get(rid))
      }
      sendReply(ch, { id, success: true, data: state })
      return
    }
    if (type === "prompt") {
      const images = command.images
      if (Array.isArray(images) && images.some((img) => Buffer.byteLength(String(img?.data ?? ""), "base64") > MAX_ATTACHMENT_BYTES)) {
        const err = `单张图片超过 ${Math.round(MAX_ATTACHMENT_BYTES / 1024 / 1024)} MiB，请在手机上压缩后重试`
        rememberPromptReceipt(ch, id, { success: false, error: err })
        sendReply(ch, { id, success: false, error: err })
        return
      }
      const data = runner.sendPrompt(command)
      rememberPromptReceipt(ch, id, { success: true, data })
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "abort") {
      const data = runner.abort()
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "set_model") {
      const data = await runner.setModel(command.modelId ?? command.id)
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "set_thinking_level") {
      const data = await runner.setThinkingLevel(command.level)
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "set_mode") {
      const data = await runner.setMode(command.mode)
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "new_session") {
      const data = await runner.newSession({ cwd: command.cwd })
      sendReply(ch, { id, success: true, data })
      return
    }
    if (type === "switch_session") {
      const data = await runner.switchSession(command.sessionPath)
      sendReply(ch, { id, success: true, data })
      return
    }
    sendReply(ch, { id, success: false, error: `不支持的命令：${type}` })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (type === "prompt") rememberPromptReceipt(ch, id, { success: false, error: message })
    sendReply(ch, { id, success: false, error: message })
  }
}

async function handleInboundMessage(ch, msg) {
  if (!msg || typeof msg !== "object") return
  if (msg.type === "pair_pub") {
    if (!ch.e2e.agree(msg.pub)) {
      ch.send({ type: "error", message: "端到端密钥协商失败，请重新配对" })
      return
    }
    const pub = Buffer.from(msg.pub, "base64url").toString("base64url")
    if (pub !== ch.phonePublicKey) {
      ch.phonePublicKey = pub
      ch.promptReceipts.clear()
    }
    console.log(`[agy-gateway:${ch.name}] 端到端加密已启用`)
    return
  }
  if (msg.type === "rpc" || msg.type === "extension_ui_response") {
    if (!ch.e2e.hasSessionKey()) {
      ch.send({ type: "error", message: "尚未完成加密配对" })
      return
    }
    const payload = ch.e2e.open(msg.sealed)
    if (!payload) return
    if (msg.type === "rpc") {
      await handleRPC(ch, payload.command, msg.id)
    }
    return
  }
  if (msg.type === "session_list") {
    const entries = await listSessionCatalog(DATA_DIRS).catch(() => [])
    const sessions = entries.map(({ path, cwd, mtime, title }) => ({
      path,
      cwd,
      mtime,
      title: title || basename(path),
    }))
    ch.send({ type: "session_list", sessions })
    return
  }
  if (msg.type === "device_status") {
    console.log(`[agy-gateway:${ch.name}] 手机${msg.online ? "已连接" : "已断开"}`)
  }
}

const LATEST_PAIR_FILE = env.AGY_LATEST_PAIR_PATH ?? join(homedir(), ".gemini", "agy-mobile-latest-pair.json")

async function printQR(label, url, ttlMinutes = 15, kind = "direct") {
  const qr = await QRCode.toString(url, { type: "terminal", small: true }).catch(() => "")
  console.log(`\n[iPhone · ${label}] 扫码配对（${ttlMinutes} 分钟有效）：`)
  if (qr) console.log(qr)
  console.log(url, "\n")
  try {
    mkdirSync(dirname(LATEST_PAIR_FILE), { recursive: true })
    let state = {}
    try { state = JSON.parse(readFileSync(LATEST_PAIR_FILE, "utf8")) } catch { /* ignore */ }
    state[kind] = { label, url, qr, createdAt: Date.now(), expiresAt: Date.now() + ttlMinutes * 60 * 1000 }
    writeFileSync(LATEST_PAIR_FILE, JSON.stringify(state, null, 2), { mode: 0o600 })
    chmodSync(LATEST_PAIR_FILE, 0o600)
  } catch { /* ignore */ }
}

// MARK: - 1. 局域网 / Tailscale 嵌入式直连模式
let localServer = null
async function startLocalDirect() {
  const ch = {
    name: "direct",
    e2e: createE2EChannel(),
    send: (obj) => localServer?.sendToDevice(obj),
    promptReceipts: new Map(),
    phonePublicKey: null,
  }
  channels.set("direct", ch)

  localServer = createLocalDirectServer({
    host: LOCAL_HOST,
    port: LOCAL_PORT,
    currentState: () => (runner.isRunning ? "running" : "idle"),
    onClientMessage: (msg) => { void handleInboundMessage(ch, msg) },
    onClientPresence: (online) => {
      console.log(`[agy-gateway:direct] 手机${online ? "已直连" : "已断开"}`)
    },
  })

  const boundPort = await localServer.listen()
  console.log(`[agy-gateway:direct] 本地直连服务已监听 ${LOCAL_HOST}:${boundPort}`)

  const { lan, tailscale } = discoverLocalAddresses()
  if (tailscale.length > 0) {
    const token = localServer.createPairToken()
    await printQR(`Tailscale 直连（Wi-Fi / 5G 通用 · ${tailscale[0].address}）`, `http://${tailscale[0].address}:${boundPort}/agy/pair#${token}.${gatewayPublicKey}`)
  } else {
    console.log("[提示] 未检测到已启动的 Tailscale（100.x.y.z）。如需用 5G 流量直连 Mac，可先在 Mac 和手机开启 Tailscale，或配置 VPS RELAY_URL。")
  }
  if (lan.length > 0) {
    const token = localServer.createPairToken()
    await printQR(`局域网直连（同 Wi-Fi · ${lan[0].address}）`, `http://${lan[0].address}:${boundPort}/agy/pair#${token}.${gatewayPublicKey}`)
  }
  if (lan.length === 0 && tailscale.length === 0) {
    const token = localServer.createPairToken()
    await printQR("本机直连 (127.0.0.1)", `http://127.0.0.1:${boundPort}/agy/pair#${token}.${gatewayPublicKey}`)
  }
}

// MARK: - 2. 自托管 VPS Relay 公网穿透模式
let relaySocket = null
function connectRelay() {
  const ch = channels.get("relay") ?? {
    name: "relay",
    e2e: createE2EChannel(),
    send: (obj) => {
      if (relaySocket?.readyState === WebSocket.OPEN) relaySocket.send(JSON.stringify(obj))
    },
    promptReceipts: new Map(),
    phonePublicKey: null,
  }
  channels.set("relay", ch)

  relaySocket = new WebSocket(RELAY_URL, { headers: { Authorization: `Bearer ${GATEWAY_TOKEN}` } })
  relaySocket.on("open", () => {
    console.log(`[agy-gateway:relay] 已连 relay ${RELAY_URL}`)
    relaySocket.send(JSON.stringify({ type: "pair_create" }))
    if (!ch.e2e.hasSessionKey()) ch.send({ type: "status", state: "idle", needsPairingKey: true })
  })
  relaySocket.on("message", async (raw) => {
    let msg
    try { msg = JSON.parse(String(raw)) } catch { return }
    if (msg.type === "pair_token") {
      const url = `${PAIR_BASE}#${msg.token}.${gatewayPublicKey}`
      await printQR("公网 Relay（Wi-Fi / 5G 通用）", url, 15, "relay")
      return
    }
    if (msg.type === "hello") return
    if (msg.type === "error") {
      console.error(`[agy-relay] ${msg.message}`)
      return
    }
    await handleInboundMessage(ch, msg)
  })
  relaySocket.on("close", () => {
    console.error("[agy-gateway:relay] relay 断开，3 秒后重连")
    if (!shuttingDown) setTimeout(connectRelay, 3000).unref?.()
  })
  relaySocket.on("error", (error) => {
    console.error(`[agy-gateway:relay] WSS 错误：${error.message}`)
  })
}

async function main() {
  const models = await runner.getAvailableModels()
  console.log(`[agy-gateway] agy 就绪（可用模型 ${models.length} 个，默认工作目录 ${runner.defaultCwd}）`)
  if (ENABLE_LOCAL) await startLocalDirect()
  if (RELAY_URL) connectRelay()
}

function shutdown() {
  shuttingDown = true
  runner.shutdown()
  localServer?.close()
  try { relaySocket?.close() } catch { /* ignore */ }
  process.exit(0)
}
process.on("SIGUSR1", () => {
  if (relaySocket?.readyState === WebSocket.OPEN) {
    relaySocket.send(JSON.stringify({ type: "pair_create" }))
  }
  if (localServer) {
    const { lan, tailscale } = discoverLocalAddresses()
    const addr = tailscale[0]?.address ?? lan[0]?.address ?? "127.0.0.1"
    const label = tailscale[0] ? `Tailscale 直连 (${addr})` : `局域网直连 (${addr})`
    const token = localServer.createPairToken()
    void printQR(label, `http://${addr}:${LOCAL_PORT}/agy/pair#${token}.${gatewayPublicKey}`, 15, "direct")
  }
})

process.on("SIGINT", shutdown)
process.on("SIGTERM", shutdown)

void main()
