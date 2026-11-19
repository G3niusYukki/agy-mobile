import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import WebSocket from "ws"

function waitMessage(ws, pred = () => true, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout waiting message")), timeoutMs)
    const onMsg = (raw) => {
      const msg = JSON.parse(String(raw))
      if (pred(msg)) {
        clearTimeout(timer)
        ws.off("message", onMsg)
        resolve(msg)
      }
    }
    ws.on("message", onMsg)
  })
}

test("agy-relay：配对 → 密文路由 → 健康检查", async () => {
  const port = 18791
  const token = "a".repeat(64)
  const proc = spawn("node", ["src/index.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, RELAY_PORT: String(port), GATEWAY_TOKEN: token },
    stdio: ["ignore", "pipe", "pipe"],
  })
  try {
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("relay did not start")), 4000)
      proc.stdout.on("data", (d) => {
        if (String(d).includes("listening")) {
          clearTimeout(t)
          resolve()
        }
      })
    })

    const gw = new WebSocket(`ws://127.0.0.1:${port}/agy/gateway`, {
      headers: { Authorization: `Bearer ${token}` },
    })
    await waitMessage(gw, (m) => m.type === "hello")
    gw.send(JSON.stringify({ type: "pair_create" }))
    const { token: pairToken } = await waitMessage(gw, (m) => m.type === "pair_token")
    assert.equal(pairToken.length, 32)

    const phone = new WebSocket(`ws://127.0.0.1:${port}/agy/client`)
    await new Promise((r) => phone.once("open", r))
    phone.send(JSON.stringify({ type: "pair", token: pairToken, pub: "test-pub" }))
    const paired = await waitMessage(phone, (m) => m.type === "paired")
    assert.equal(paired.deviceToken.length, 64)
    const pubFrame = await waitMessage(gw, (m) => m.type === "pair_pub")
    assert.equal(pubFrame.pub, "test-pub")

    phone.send(JSON.stringify({ type: "rpc", id: "1", sealed: "cipher-req" }))
    const forwarded = await waitMessage(gw, (m) => m.type === "rpc")
    assert.equal(forwarded.sealed, "cipher-req")

    gw.send(JSON.stringify({ type: "rpc_response", sealed: "cipher-res" }))
    const reply = await waitMessage(phone, (m) => m.type === "rpc_response")
    assert.equal(reply.sealed, "cipher-res")

    const health = await fetch(`http://127.0.0.1:${port}/agy/healthz`).then((r) => r.json())
    assert.deepEqual(health, { ok: true, gateway: true, device: true })

    gw.close()
    phone.close()
  } finally {
    proc.kill("SIGTERM")
  }
})
