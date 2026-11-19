#!/usr/bin/env node
// 向后台运行的 agy-mobile 网关发送 SIGUSR1，即时生成并打印新的扫码配对二维码。
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const latestPath = process.env.AGY_LATEST_PAIR_PATH ?? join(homedir(), ".gemini", "agy-mobile-latest-pair.json")

function readState() {
  try { return JSON.parse(readFileSync(latestPath, "utf8")) } catch { return {} }
}

const before = readState()
const beforeTs = Math.max(before.relay?.createdAt ?? 0, before.direct?.createdAt ?? 0)

let pids = []
try {
  const out = execFileSync("pgrep", ["-f", "agy-mobile/gateway/src/index.mjs"], { encoding: "utf8" }).trim()
  pids = out.split(/\s+/).map(Number).filter((n) => Number.isInteger(n) && n > 0 && n !== process.pid)
} catch {
  // 未找到运行中的网关进程
}

if (pids.length === 0) {
  console.error("未检测到运行中的 agy-mobile 网关。请先运行 launchctl kickstart -k gui/$(id -u)/com.agymobile.gateway 或 npm --prefix gateway start。")
  process.exit(1)
}

for (const pid of pids) {
  try { process.kill(pid, "SIGUSR1") } catch { /* ignore */ }
}

const deadline = Date.now() + 5000
while (Date.now() < deadline) {
  const cur = readState()
  const entry = cur.relay?.createdAt > beforeTs ? cur.relay : (cur.direct?.createdAt > beforeTs ? cur.direct : null)
  if (entry) {
    console.log(`\n[iPhone · ${entry.label}] 扫码配对（15 分钟有效）：`)
    if (entry.qr) console.log(entry.qr)
    console.log(entry.url, "\n")
    process.exit(0)
  }
  await new Promise((r) => setTimeout(r, 150))
}

const fallback = readState()
const best = fallback.relay ?? fallback.direct
if (best && best.expiresAt > Date.now()) {
  console.log(`\n[iPhone · ${best.label}] 扫码配对：`)
  if (best.qr) console.log(best.qr)
  console.log(best.url, "\n")
  process.exit(0)
}

console.error("等待网关生成新配对码超时，请查看 ~/Library/Logs/agy-mobile-gateway.log")
process.exit(1)
