import { createServer } from "node:http"
import { randomBytes } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { homedir, networkInterfaces } from "node:os"
import { dirname, join } from "node:path"
import { WebSocketServer, WebSocket } from "ws"

const PAIR_TTL_MS = 5 * 60 * 1000
const DEVICE_TTL_MS = 90 * 24 * 60 * 60 * 1000

function isTailscaleIPv4(ip) {
  const parts = ip.split(".").map(Number)
  return parts.length === 4 && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127
}

function isPrivateLanIPv4(ip) {
  const parts = ip.split(".").map(Number)
  if (parts.length !== 4) return false
  if (parts[0] === 10) return true
  if (parts[0] === 192 && parts[1] === 168) return true
  if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true
  return false
}

export function discoverLocalAddresses() {
  const lan = []
  const tailscale = []
  const ifaces = networkInterfaces()
  for (const [name, list] of Object.entries(ifaces)) {
    for (const info of list ?? []) {
      if (info.family !== "IPv4" || info.internal) continue
      if (isTailscaleIPv4(info.address)) tailscale.push({ name, address: info.address })
      else if (isPrivateLanIPv4(info.address)) lan.push({ name, address: info.address })
    }
  }
  return { lan, tailscale }
}

/**
 * 嵌入式直连 WebSocket 服务（用于局域网 / Tailscale 零 VPS 部署）。
 * 复用与 Relay 完全一致的配对/令牌/密文帧协议。
 */
export function createLocalDirectServer(options) {
  const host = options.host ?? "0.0.0.0"
  const port = Number(options.port ?? 8790)
  const devicesPath = options.devicesPath ?? join(homedir(), ".gemini", "agy-mobile-devices.json")
  const onClientMessage = options.onClientMessage
  const onClientPresence = options.onClientPresence ?? (() => {})

  const pairTokens = new Map()
  const devices = loadDevices(devicesPath)
  let activeDevice = null

  function loadDevices(path) {
    const map = new Map()
    try {
      if (existsSync(path)) {
        const parsed = JSON.parse(readFileSync(path, "utf8"))
        const now = Date.now()
        for (const [token, expiresAt] of Object.entries(parsed ?? {})) {
          if (typeof expiresAt === "number" && expiresAt > now) map.set(token, expiresAt)
        }
      }
    } catch { /* ignore */ }
    return map
  }

  function saveDevices() {
    try {
      mkdirSync(dirname(devicesPath), { recursive: true })
      const obj = Object.fromEntries(devices.entries())
      writeFileSync(devicesPath, JSON.stringify(obj, null, 2), { mode: 0o600 })
      chmodSync(devicesPath, 0o600)
    } catch { /* ignore */ }
  }

  function send(ws, obj) {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
  }

  function closeOld(ws, reason) {
    try { ws.close(1000, reason) } catch { /* ignore */ }
  }

  const server = createServer((req, res) => {
    if (req.url === "/agy/healthz") {
      res.writeHead(200, { "content-type": "application/json" })
      res.end(JSON.stringify({ ok: true, mode: "direct", device: !!activeDevice }))
      return
    }
    res.writeHead(404)
    res.end()
  })

  const wss = new WebSocketServer({ noServer: true, maxPayload: 12 * 1024 * 1024 })

  server.on("upgrade", (req, socket, head) => {
    let pathname
    try {
      pathname = new URL(req.url ?? "/", "http://localhost").pathname
    } catch {
      socket.destroy()
      return
    }
    if (pathname !== "/agy/client") {
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req)
    })
  })

  function attach(ws, deviceToken) {
    if (ws.pairTimer) {
      clearTimeout(ws.pairTimer)
      ws.pairTimer = null
    }
    if (activeDevice && activeDevice !== ws) closeOld(activeDevice, "replaced")
    activeDevice = ws
    ws.deviceToken = deviceToken
    send(ws, { type: "paired", deviceToken })
    send(ws, { type: "status", state: options.currentState?.() ?? "idle" })
    onClientPresence(true)
  }

  wss.on("connection", (ws, req) => {
    const auth = String(req.headers.authorization ?? "")
    const bearer = auth.startsWith("Bearer ") ? auth.slice(7) : ""
    if (bearer && devices.has(bearer) && devices.get(bearer) > Date.now()) {
      attach(ws, bearer)
    } else {
      ws.pairTimer = setTimeout(() => ws.close(4408, "pair timeout"), 30_000)
    }

    ws.on("pong", () => { ws.lastPong = Date.now() })
    ws.on("message", (raw) => {
      let msg
      try { msg = JSON.parse(String(raw)) } catch {
        send(ws, { type: "error", message: "invalid json" })
        return
      }
      if (!msg || typeof msg !== "object") return
      if (msg.type === "pair") {
        const token = String(msg.token ?? "")
        const expiresAt = pairTokens.get(token)
        if (!expiresAt || expiresAt <= Date.now()) {
          send(ws, { type: "error", message: "pair token invalid or expired" })
          return
        }
        pairTokens.delete(token)
        const deviceToken = randomBytes(32).toString("hex")
        devices.set(deviceToken, Date.now() + DEVICE_TTL_MS)
        saveDevices()
        attach(ws, deviceToken)
        if (typeof msg.pub === "string") onClientMessage({ type: "pair_pub", pub: msg.pub })
        return
      }
      if (!ws.deviceToken) {
        send(ws, { type: "error", message: "not paired" })
        return
      }
      onClientMessage(msg)
    })

    ws.on("close", () => {
      if (ws.pairTimer) clearTimeout(ws.pairTimer)
      if (activeDevice === ws) {
        activeDevice = null
        onClientPresence(false)
      }
    })
  })

  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.readyState !== WebSocket.OPEN) continue
      if (ws.lastPong && Date.now() - ws.lastPong > 90_000) ws.terminate()
      else ws.ping()
    }
  }, 30_000)
  heartbeat.unref?.()

  return {
    createPairToken() {
      const token = randomBytes(16).toString("hex")
      pairTokens.set(token, Date.now() + PAIR_TTL_MS)
      return token
    },
    sendToDevice(obj) {
      send(activeDevice, obj)
    },
    hasDevice() {
      return activeDevice?.readyState === WebSocket.OPEN
    },
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject)
        server.listen(port, host, () => {
          server.off("error", reject)
          const addr = server.address()
          resolve(typeof addr === "object" && addr ? addr.port : port)
        })
      })
    },
    close() {
      clearInterval(heartbeat)
      try { activeDevice?.close() } catch { /* ignore */ }
      try { wss.close() } catch { /* ignore */ }
      try { server.close() } catch { /* ignore */ }
    },
  }
}
