import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { createCipheriv, createDecipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from "node:crypto"
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { DatabaseSync } from "node:sqlite"
import WebSocket from "ws"
import { AgyRunner, parseAgyModelsOutput } from "../src/agy-runner.mjs"
import { extractUserRequestText, readSessionHistoryStrict } from "../src/history.mjs"
import { listSessionCatalog } from "../src/session-catalog.mjs"

const SPKI_PREFIX = Buffer.from("302a300506032b656e032100", "hex")

function makeClientE2E(gatewayPubBase64url) {
  const { publicKey, privateKey } = generateKeyPairSync("x25519")
  const pubRaw = publicKey.export({ format: "der", type: "spki" }).subarray(-32).toString("base64url")
  const peerRaw = Buffer.from(gatewayPubBase64url, "base64url")
  const peer = createPublicKey({ key: Buffer.concat([SPKI_PREFIX, peerRaw]), format: "der", type: "spki" })
  const secret = diffieHellman({ privateKey, publicKey: peer })
  const key = Buffer.from(hkdfSync("sha256", secret, "agy-mobile-e2e-v1", "agy-mobile", 32))
  return {
    pub: pubRaw,
    seal(value) {
      const iv = randomBytes(12)
      const cipher = createCipheriv("aes-256-gcm", key, iv)
      const enc = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()])
      return Buffer.concat([iv, enc, cipher.getAuthTag()]).toString("base64url")
    },
    open(sealed) {
      const blob = Buffer.from(sealed, "base64url")
      const decipher = createDecipheriv("aes-256-gcm", key, blob.subarray(0, 12))
      decipher.setAuthTag(blob.subarray(blob.length - 16))
      return JSON.parse(Buffer.concat([decipher.update(blob.subarray(12, blob.length - 16)), decipher.final()]).toString("utf8"))
    },
  }
}

test("parseAgyModelsOutput 解析空格与制表符分隔的模型列表", () => {
  const raw = "gemini-4-neon-xhigh\tGemini 4 Neon (XHigh)\nclaude-opus-5-5-high      Claude Opus 5.5 (High)\ngpt-oss-120b-medium\tGPT-OSS 120B (Medium)\n"
  const models = parseAgyModelsOutput(raw)
  assert.equal(models.length, 3)
  assert.deepEqual(models.map((m) => [m.provider, m.id, m.displayName]), [
    ["Google", "gemini-4-neon-xhigh", "Gemini 4 Neon (XHigh)"],
    ["Anthropic", "claude-opus-5-5-high", "Claude Opus 5.5 (High)"],
    ["OpenAI", "gpt-oss-120b-medium", "GPT-OSS 120B (Medium)"],
  ])
})

test("session-catalog 与 history 正确解析 Antigravity SQLite 与 transcript_full.jsonl", async () => {
  const root = mkdtempSync(join(tmpdir(), "agy-cat-test-"))
  try {
    const convId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    const db = new DatabaseSync(join(root, "conversation_summaries.db"))
    db.exec(`
      CREATE TABLE conversation_summaries (
        conversation_id text PRIMARY KEY,
        title text NOT NULL DEFAULT "",
        preview text NOT NULL DEFAULT "",
        step_count integer NOT NULL DEFAULT 0,
        last_modified_time datetime NOT NULL,
        workspace_uris text NOT NULL,
        status text NOT NULL DEFAULT "",
        parent_conversation_id text NOT NULL DEFAULT "",
        nesting_depth integer NOT NULL DEFAULT 0,
        killed numeric NOT NULL DEFAULT false
      )
    `)
    db.prepare(`
      INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?, ?, '', 0, 0)
    `).run(convId, "Fix Auth Flow", "Inspect login middleware", 4, "2026-11-19 08:00:00+00:00", '["file:///tmp/demo-proj"]', "IDLE")
    db.prepare(`
      INSERT INTO conversation_summaries VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0)
    `).run("bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee", "Subagent", "Hidden", 2, "2026-11-19 08:01:00+00:00", '["file:///tmp/demo-proj"]', "IDLE", convId)
    db.close()

    const logsDir = join(root, "brain", convId, ".system_generated", "logs")
    mkdirSync(logsDir, { recursive: true })
    writeFileSync(join(logsDir, "transcript_full.jsonl"), [
      JSON.stringify({ step_index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "<USER_REQUEST>\n检查登录中间件\n</USER_REQUEST>\n<ADDITIONAL_METADATA>time</ADDITIONAL_METADATA>" }),
      JSON.stringify({ step_index: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "先读取文件。", tool_calls: [{ name: "view_file", arguments: { Path: "/tmp/demo-proj/auth.ts" } }] }),
      JSON.stringify({ step_index: 2, source: "MODEL", type: "GENERIC", status: "DONE", content: "export function auth() {}" }),
      JSON.stringify({ step_index: 3, source: "MODEL", type: "PLANNER_RESPONSE", content: "登录逻辑正常。" }),
    ].join("\n"))

    assert.equal(extractUserRequestText("<USER_REQUEST>\n你好\n</USER_REQUEST>"), "你好")
    assert.equal(
      extractUserRequestText("<USER_REQUEST>\n<DESKTOP_CONTINUATION_CONTEXT>\n旧上下文\n</DESKTOP_CONTINUATION_CONTEXT>\n\n继续分析\n</USER_REQUEST>"),
      "继续分析"
    )

    const catalog = await listSessionCatalog([root])
    assert.equal(catalog.length, 1)
    assert.equal(catalog[0].path, convId)
    assert.equal(catalog[0].title, "Fix Auth Flow")
    assert.equal(catalog[0].cwd, "/tmp/demo-proj")

    const history = readSessionHistoryStrict(convId, [root])
    assert.equal(history.sessionPath, convId)
    assert.equal(history.messages.length, 4)
    assert.equal(history.messages[0].role, "user")
    assert.equal(history.messages[0].text, "检查登录中间件")
    assert.equal(history.messages[1].role, "assistant")
    assert.equal(history.messages[2].role, "tool")
    assert.equal(history.messages[2].toolTitle, "view_file")
    assert.match(history.messages[2].text, /export function auth/)
    assert.equal(history.messages[3].text, "登录逻辑正常。")
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test("agy-gateway 直连模式：扫码配对 → E2E 加密 → 模型/模式切换 → 工具流式输出", async () => {
  const work = mkdtempSync(join(tmpdir(), "agy-gw-test-"))
  const fakeAgy = new URL("./fake-agy.mjs", import.meta.url).pathname
  chmodSync(fakeAgy, 0o755)
  const port = 18790

  const proc = spawn("node", ["src/index.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      ENABLE_LOCAL: "1",
      LOCAL_HOST: "127.0.0.1",
      LOCAL_PORT: String(port),
      AGY_BIN: fakeAgy,
      AGY_CWD: work,
      AGY_MOBILE_GATEWAY_KEY_PATH: join(work, "gw.key"),
      AGY_LATEST_PAIR_PATH: join(work, "latest-pair.json"),
      RELAY_URL: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  })

  try {
    const pairLink = await new Promise((resolve, reject) => {
      let out = ""
      const t = setTimeout(() => reject(new Error(`gateway did not print pair link:\n${out}`)), 6000)
      proc.stdout.on("data", (d) => {
        out += String(d)
        const match = /http:\/\/[^\s]+\/agy\/pair#([0-9a-f]{32})\.([A-Za-z0-9_-]+)/.exec(out)
        if (match) {
          clearTimeout(t)
          resolve({ url: match[0], token: match[1], pub: match[2] })
        }
      })
    })

    const e2e = makeClientE2E(pairLink.pub)
    const ws = new WebSocket(`ws://127.0.0.1:${port}/agy/client`)
    await new Promise((r) => ws.once("open", r))

    const inbox = []
    const waiters = []
    ws.on("message", (raw) => {
      const msg = JSON.parse(String(raw))
      const idx = waiters.findIndex((w) => w.pred(msg))
      if (idx >= 0) waiters.splice(idx, 1)[0].resolve(msg)
      else inbox.push(msg)
    })
    function nextMsg(pred, ms = 5000) {
      const idx = inbox.findIndex(pred)
      if (idx >= 0) return Promise.resolve(inbox.splice(idx, 1)[0])
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("timeout waiting frame")), ms)
        waiters.push({
          pred,
          resolve: (m) => { clearTimeout(timer); resolve(m) },
        })
      })
    }

    ws.send(JSON.stringify({ type: "pair", token: pairLink.token, pub: e2e.pub }))
    const paired = await nextMsg((m) => m.type === "paired")
    assert.equal(paired.deviceToken.length, 64)

    async function rpc(command) {
      ws.send(JSON.stringify({ type: "rpc", id: command.id, sealed: e2e.seal({ command }) }))
      const frame = await nextMsg((m) => m.type === "rpc_response")
      return e2e.open(frame.sealed)
    }

    const modelsRes = await rpc({ type: "get_available_models", id: "m1" })
    assert.equal(modelsRes.success, true)
    assert.equal(modelsRes.data.models.length, 3)

    const modeRes = await rpc({ type: "set_mode", id: "mode1", mode: "plan" })
    assert.equal(modeRes.success, true)
    assert.equal(modeRes.data.mode, "plan")

    const effortRes = await rpc({ type: "set_thinking_level", id: "eff1", level: "xhigh" })
    assert.equal(effortRes.success, true)
    assert.equal(effortRes.data.model.id, "gemini-4-neon-xhigh")

    const promptRes = await rpc({ type: "prompt", id: "p1", message: "hello use-tool" })
    assert.equal(promptRes.success, true)
    assert.equal(promptRes.data.disposition, "started")

    const events = []
    while (true) {
      const frame = await nextMsg((m) => m.type === "event")
      const ev = e2e.open(frame.sealed)
      events.push(ev)
      if (ev.type === "agent_settled") break
    }
    assert.ok(events.some((e) => e.type === "tool_execution_start" && e.toolName === "run_command"))
    assert.ok(events.some((e) => e.type === "tool_execution_end" && e.toolName === "run_command" && e.durationMs === 120))
    const finalMsg = events.find((e) => e.type === "message_end")
    assert.match(finalMsg.message.content[0].text, /Echo \[gemini-4-neon-xhigh\/plan\]: hello use-tool/)

    ws.close()
  } finally {
    proc.kill("SIGTERM")
    rmSync(work, { recursive: true, force: true })
  }
})

test("AgyRunner 切入桌面端会话时自动注入近期上下文且不触发 trajectory not found", async () => {
  const work = mkdtempSync(join(tmpdir(), "agy-desktop-branch-"))
  const desktopDir = join(work, "antigravity")
  const cliDir = join(work, "antigravity-cli")
  const desktopId = "a761132b-365b-4c7e-ab7c-4530f56fd313"
  const fakeAgy = new URL("./fake-agy.mjs", import.meta.url).pathname
  chmodSync(fakeAgy, 0o755)

  const prevCliEnv = process.env.FAKE_AGY_CLI_DIR
  process.env.FAKE_AGY_CLI_DIR = cliDir
  try {
    mkdirSync(join(cliDir, "conversations"), { recursive: true })
    const logsDir = join(desktopDir, "brain", desktopId, ".system_generated", "logs")
    mkdirSync(logsDir, { recursive: true })
    writeFileSync(join(logsDir, "transcript_full.jsonl"), [
      JSON.stringify({ step_index: 0, source: "USER_EXPLICIT", type: "USER_INPUT", content: "<USER_REQUEST>\n分析 iOS UI 配色\n</USER_REQUEST>" }),
      JSON.stringify({ step_index: 1, source: "MODEL", type: "PLANNER_RESPONSE", content: "建议改为极简曜石/钛银单色。" }),
    ].join("\n"))

    const events = []
    let settleResolve
    let settled = new Promise((r) => { settleResolve = r })

    const runner = new AgyRunner({
      agyBin: fakeAgy,
      cwd: work,
      dataDirs: [cliDir, desktopDir],
      cliDataDir: cliDir,
      onEvent(ev) {
        events.push(ev)
        if (ev.type === "agent_settled") settleResolve()
      },
    })

    await runner.switchSession(desktopId)
    assert.equal(runner.conversationId, desktopId)
    assert.equal(runner.cliConversationId, null)

    runner.sendPrompt({ message: "现在帮我构建并安装" })
    await settled

    const reply1 = events.find((e) => e.type === "message_end")
    assert.ok(reply1, "应收到第一轮回复")
    assert.equal(reply1.sessionPath, desktopId)
    assert.doesNotMatch(reply1.message.content[0].text, /trajectory not found/)
    assert.match(reply1.message.content[0].text, /DESKTOP_CONTINUATION_CONTEXT/)
    assert.match(reply1.message.content[0].text, /分析 iOS UI 配色/)
    assert.match(reply1.message.content[0].text, /现在帮我构建并安装/)

    // 分支关联已建立，后续发言应直接复用 CLI 轨迹且不再重复注入上下文
    const linkedId = runner.getLinkedCliSession(desktopId)
    assert.equal(linkedId, "11111111-2222-4333-8444-555555555555")

    events.length = 0
    settled = new Promise((r) => { settleResolve = r })
    runner.sendPrompt({ message: "第二轮追问" })
    await settled

    const reply2 = events.find((e) => e.type === "message_end")
    assert.ok(reply2, "应收到第二轮回复")
    assert.equal(reply2.sessionPath, desktopId)
    assert.doesNotMatch(reply2.message.content[0].text, /DESKTOP_CONTINUATION_CONTEXT/)
    assert.match(reply2.message.content[0].text, /第二轮追问/)

    runner.shutdown()
  } finally {
    if (prevCliEnv === undefined) delete process.env.FAKE_AGY_CLI_DIR
    else process.env.FAKE_AGY_CLI_DIR = prevCliEnv
    rmSync(work, { recursive: true, force: true })
  }
})
