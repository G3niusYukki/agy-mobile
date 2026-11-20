#!/usr/bin/env node
// Deterministic fake `agy` CLI implementing `models` and `--input-format stream-json --output-format stream-json`.
import { existsSync } from "node:fs"
import { join } from "node:path"
import { createInterface } from "node:readline"

const args = process.argv.slice(2)
if (args[0] === "models") {
  console.log("gemini-4-neon-high        Gemini 4 Neon (High)")
  console.log("gemini-4-neon-xhigh       Gemini 4 Neon (XHigh)")
  console.log("claude-opus-5-5-high      Claude Opus 5.5 (High)")
  process.exit(0)
}

function flagValue(name) {
  const idx = args.indexOf(name)
  return idx >= 0 && idx + 1 < args.length ? args[idx + 1] : null
}

const requestedConversation = flagValue("--conversation")
const conversationId = requestedConversation ?? "11111111-2222-4333-8444-555555555555"
const model = flagValue("--model") ?? "gemini-4-neon-high"
const mode = flagValue("--mode") ?? "default"

const cliDir = process.env.FAKE_AGY_CLI_DIR
const missingTrajectory = Boolean(
  requestedConversation &&
  cliDir &&
  !existsSync(join(cliDir, "conversations", `${requestedConversation}.db`))
)

console.log(JSON.stringify({
  event: "init",
  conversation_id: conversationId,
  init: { model, cwd: process.cwd(), permission_mode: mode },
}))

let stepIndex = 0
let turns = 0

const rl = createInterface({ input: process.stdin })
rl.on("line", (line) => {
  const trimmed = line.trim()
  if (!trimmed) return
  let payload
  try { payload = JSON.parse(trimmed) } catch { return }
  const content = String(payload?.message?.content ?? "")
  turns += 1

  if (missingTrajectory) {
    console.log(JSON.stringify({
      event: "result",
      result: {
        conversation_id: conversationId,
        status: "ERROR",
        error: `failed to send message: not_found: trajectory not found: ${conversationId}: not found`,
      },
    }))
    return
  }

  const userStep = stepIndex++
  console.log(JSON.stringify({
    event: "step_update",
    step_update: { conversation_id: conversationId, step_index: userStep, state: "DONE", step_type: "user_input" },
  }))

  if (content.includes("use-tool")) {
    const toolStep = stepIndex++
    console.log(JSON.stringify({
      event: "step_update",
      step_update: {
        conversation_id: conversationId,
        step_index: toolStep,
        state: "ACTIVE",
        step_type: "tool",
        tool_name: "run_command",
        tool_info: { name: "run_command", parameters: { CommandLine: "echo hi" } },
      },
    }))
    console.log(JSON.stringify({
      event: "step_update",
      step_update: {
        conversation_id: conversationId,
        step_index: toolStep,
        state: "DONE",
        step_type: "tool",
        tool_name: "run_command",
        duration_seconds: 0.12,
        tool_info: { name: "run_command", parameters: { CommandLine: "echo hi" }, output: "hi\n" },
      },
    }))
  }

  const replyStep = stepIndex++
  const cwdSuffix = content.includes("show-cwd") ? ` [cwd=${process.cwd()}]` : ""
  const answer = `Echo [${model}/${mode}]: ${content}${cwdSuffix}`
  console.log(JSON.stringify({
    event: "step_update",
    step_update: {
      conversation_id: conversationId,
      step_index: replyStep,
      state: "ACTIVE",
      step_type: "agent_response",
      text_delta: answer,
    },
  }))
  console.log(JSON.stringify({
    event: "step_update",
    step_update: {
      conversation_id: conversationId,
      step_index: replyStep,
      state: "DONE",
      step_type: "agent_response",
      text_delta: "",
      duration_seconds: 0.25,
    },
  }))
  console.log(JSON.stringify({
    event: "result",
    result: {
      conversation_id: conversationId,
      status: "SUCCESS",
      response: answer,
      duration_seconds: 0.3,
      num_turns: turns,
    },
  }))
})
