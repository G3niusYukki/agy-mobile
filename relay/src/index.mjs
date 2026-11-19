// Antigravity Mobile relay：gateway 与 iPhone 之间的最小密文路由层。
// 不解析业务内容、不落盘消息、不接触 Antigravity 凭据。
import { createServer } from "node:http"
import { randomBytes } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"
import { WebSocketServer, WebSocket } from "ws"

const HOST = process.env.RELAY_HOST ?? "127.0.0.1"
const PORT = Number(process.env.RELAY_PORT ?? 8791)
const GATEWAY_TOKEN = process.env.GATEWAY_TOKEN ?? ""
const DEVICES_PATH = process.env.DEVICES_PATH ?? ""
const PAIR_TTL_MS = 15 * 60 * 1000
const DEVICE_TTL_MS = 90 * 24 * 60 * 60 * 1000
const EVENT_BACKLOG = 200

if (!GATEWAY_TOKEN) {
  console.error("缺少 GATEWAY_TOKEN")
  process.exit(1)
}

function loadDevices(filePath) {
  const map = new Map()
  if (!filePath || !existsSync(filePath)) return map
  try {
    const parsed = JSON.parse(readFileSync(filePath, "utf8"))
    const now = Date.now()
    for (const [token, expiresAt] of Object.entries(parsed ?? {})) {
      if (typeof expiresAt === "number" && expiresAt > now) {
        map.set(token, { expiresAt })
      }
    }
  } catch (error) {
    console.error(`[agy-relay] 读取设备列表失败: ${error?.message ?? error}`)
  }
  return map
}

function saveDevices(filePath, map) {
  if (!filePath) return
  try {
    mkdirSync(dirname(filePath), { recursive: true })
    const now = Date.now()
    const obj = {}
    for (const [token, info] of map.entries()) {
      if (info.expiresAt > now) obj[token] = info.expiresAt
    }
    writeFileSync(filePath, JSON.stringify(obj, null, 2), { mode: 0o600 })
    chmodSync(filePath, 0o600)
  } catch (error) {
    console.error(`[agy-relay] 保存设备列表失败: ${error?.message ?? error}`)
  }
}

const pairTokens = new Map()
const devices = loadDevices(DEVICES_PATH)
let gateway = null
let device = null
let backlog = []

function send(ws, obj) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
}
function safeSend(ws, obj) {
  try {
    send(ws, obj)
  } catch {
    // 单个客户端写失败不影响路由
  }
}
function broadcastToDevice(obj) {
  safeSend(device, obj)
  if (obj.type === "event" && obj.sealed) {
    backlog.push(obj)
    if (backlog.length > EVENT_BACKLOG) backlog.splice(0, backlog.length - EVENT_BACKLOG)
  }
}
function broadcastToGateway(obj) {
  safeSend(gateway, obj)
}
function closeOld(ws, reason) {
  try {
    ws.close(1000, reason)
  } catch {
    // 已关闭
  }
}

const server = createServer((req, res) => {
  if (req.url === "/agy/healthz") {
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ ok: true, gateway: !!gateway, device: !!device }))
    return
  }
  res.writeHead(404)
  res.end()
})

const wss = new WebSocketServer({ noServer: true, maxPayload: 12 * 1024 * 1024 })
server.on("upgrade", (req, socket, head) => {
  let path
  try {
    path = new URL(req.url ?? "/", "http://localhost").pathname
  } catch {
    socket.destroy()
    return
  }
  if (path !== "/agy/gateway" && path !== "/agy/client") {
    socket.destroy()
    return
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.role = null
    wss.emit("connection", ws, req, path)
  })
})

wss.on("connection", (ws, req, path) => {
  const auth = String(req.headers.authorization ?? "")
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7) : ""
  const role = path.endsWith("/gateway") ? "gateway" : "client"

  if (role === "gateway") {
    if (bearer !== GATEWAY_TOKEN) {
      ws.close(4403, "unauthorized")
      return
    }
    if (gateway && gateway !== ws) closeOld(gateway, "replaced")
    gateway = ws
    ws.role = "gateway"
    send(ws, { type: "hello", role: "gateway" })
    safeSend(device, { type: "status", state: "idle", needsPairingKey: true })
  } else {
    ws.role = "client"
    if (bearer && devices.has(bearer) && devices.get(bearer).expiresAt > Date.now()) {
      attachDevice(ws, bearer)
    } else {
      const timer = setTimeout(() => ws.close(4408, "pair timeout"), 30_000)
      ws.pairTimer = timer
    }
  }

  ws.on("pong", () => {
    ws.lastPong = Date.now()
  })
  ws.on("message", (raw) => {
    let msg
    try {
      msg = JSON.parse(String(raw))
    } catch {
      send(ws, { type: "error", message: "invalid json" })
      return
    }
    if (!msg || typeof msg !== "object") return
    if (role === "gateway") onGatewayMessage(ws, msg)
    else onClientMessage(ws, msg)
  })
  ws.on("close", () => {
    if (ws.pairTimer) clearTimeout(ws.pairTimer)
    if (gateway === ws) {
      gateway = null
      safeSend(device, { type: "status", state: "unknown" })
    }
    if (device === ws) {
      device = null
      broadcastToGateway({ type: "device_status", online: false })
    }
  })
})

function attachDevice(ws, deviceToken) {
  if (ws.pairTimer) {
    clearTimeout(ws.pairTimer)
    ws.pairTimer = null
  }
  if (device && device !== ws) closeOld(device, "replaced")
  device = ws
  ws.deviceToken = deviceToken
  send(ws, { type: "paired", deviceToken })
  send(ws, { type: "status", state: gateway ? "idle" : "unknown" })
  for (const frame of backlog) safeSend(ws, frame)
  broadcastToGateway({ type: "device_status", online: true })
}

function onClientMessage(ws, msg) {
  if (msg.type === "pair") {
    const token = String(msg.token ?? "")
    const expiresAt = pairTokens.get(token)
    if (!expiresAt || expiresAt <= Date.now()) {
      send(ws, { type: "error", message: "pair token invalid or expired" })
      return
    }
    pairTokens.delete(token)
    const deviceToken = randomBytes(32).toString("hex")
    devices.set(deviceToken, { expiresAt: Date.now() + DEVICE_TTL_MS })
    saveDevices(DEVICES_PATH, devices)
    attachDevice(ws, deviceToken)
    if (typeof msg.pub === "string") broadcastToGateway({ type: "pair_pub", pub: msg.pub })
    return
  }
  if (!ws.deviceToken) {
    send(ws, { type: "error", message: "not paired" })
    return
  }
  if (["rpc", "extension_ui_response", "session_list", "session_switch", "session_new", "pair_pub"].includes(msg.type)) {
    if (!gateway) {
      send(ws, { type: "error", message: "gateway offline" })
      return
    }
    broadcastToGateway(msg)
    return
  }
  send(ws, { type: "error", message: "unsupported message" })
}

function onGatewayMessage(ws, msg) {
  if (msg.type === "pair_create") {
    const token = randomBytes(16).toString("hex")
    pairTokens.set(token, Date.now() + PAIR_TTL_MS)
    send(ws, { type: "pair_token", token, expiresAt: Date.now() + PAIR_TTL_MS })
    return
  }
  if (["rpc_response", "event", "status", "session_list", "error"].includes(msg.type)) {
    broadcastToDevice(msg)
    return
  }
  send(ws, { type: "error", message: "unsupported message" })
}

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.readyState !== WebSocket.OPEN) continue
    if (ws.lastPong && Date.now() - ws.lastPong > 90_000) ws.terminate()
    else ws.ping()
  }
}, 30_000)
heartbeat.unref?.()

server.listen(PORT, HOST, () => {
  console.log(`[agy-relay] listening ${HOST}:${PORT}`)
})

export function __testServer() {
  return { server, wss }
}
