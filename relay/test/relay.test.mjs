import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
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

test("agy-relay：配对 → 密文路由 → 健康检查 → 重启持久化设备令牌", async () => {
  const port = 18791
  const token = "a".repeat(64)
  const dir = mkdtempSync(join(tmpdir(), "agy-relay-test-"))
  const devicesPath = join(dir, "devices.json")

  function startRelay() {
    return spawn("node", ["src/index.mjs"], {
      cwd: new URL("..", import.meta.url),
      env: { ...process.env, RELAY_PORT: String(port), GATEWAY_TOKEN: token, DEVICES_PATH: devicesPath },
      stdio: ["ignore", "pipe", "pipe"],
    })
  }
  function waitListening(p) {
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("relay did not start")), 4000)
      p.stdout.on("data", (d) => {
        if (String(d).includes("listening")) {
          clearTimeout(t)
          resolve()
        }
      })
    })
  }

  let proc = startRelay()
  try {
    await waitListening(proc)

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
    await new Promise((resolve) => {
      proc.once("exit", resolve)
      proc.kill("SIGTERM")
    })

    // 重启 relay 后，原 deviceToken 无需重新扫码即可直接恢复连接
    proc = startRelay()
    await waitListening(proc)
    const resumed = new WebSocket(`ws://127.0.0.1:${port}/agy/client`, {
      headers: { Authorization: `Bearer ${paired.deviceToken}` },
    })
    const resumedPaired = await waitMessage(resumed, (m) => m.type === "paired")
    assert.equal(resumedPaired.deviceToken, paired.deviceToken)
    resumed.close()
  } finally {
    try { proc.kill("SIGTERM") } catch { /* ignore */ }
    rmSync(dir, { recursive: true, force: true })
  }
})
