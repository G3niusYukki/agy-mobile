# Antigravity Mobile (`agy-mobile`)

原生 SwiftUI（iOS 26+ / iPhone Duo）移动端客户端，让你在 iPhone 上远程驱动 Mac 本机的 Google Antigravity CLI（`agy`），实时查看思考阶段、工具执行进度、Diff 代码改动与会话历史。

```text
直连模式（零部署）：iPhone App ←─ E2E WS ─→ Mac gateway (内嵌直连服务) ←─ stream-json ─→ agy
中继模式（公网穿透）：iPhone App ←─ E2E WSS ─→ VPS relay ←─ E2E WSS ─→ Mac gateway ←─ stream-json ─→ agy
```

无论直连还是公网中继，消息正文、图片附件、会话目录与历史记录均在手机与 Mac 之间通过 **X25519 + HKDF-SHA256 + AES-256-GCM** 端到端加密。

## 核心能力

- **双模连接与无感重连**：Mac 网关默认开启嵌入式直连服务（自动识别局域网 IP 与 Tailscale `100.x.y.z` IP，零 VPS 即可扫码使用），同时也支持接入自托管公网 Relay；切后台/切网回前台自动重连具备 2.5 秒静默宽限期，不闪烁错误横幅，仅持续失败时温和提示。
- **Antigravity 原生控制**：直接托管 `agy --input-format stream-json --output-format stream-json`，支持切换全部 `agy models`（Google / Anthropic / OpenAI）、5 档思考强度（`low / medium / high / xhigh / max`）与运行模式（`默认 / 自动编辑 / 规划模式`）。
- **多工作区与本地会话恢复**：网关自动聚合 Antigravity 历史工作区与本机 Git 项目目录（也支持通过 `AGY_WORKSPACES` 固定常用目录），手机端新建会话时可直接选择对应 `cwd`；通过 Node 内置 `node:sqlite` 只读扫描 `conversation_summaries.db` 与 `transcript_full.jsonl`，支持按工作目录分组检索并无缝续接桌面端与 CLI 会话。
- **iOS 26 原生体验**：液态玻璃变形输入栏、呼吸思考扫光、语义化工具卡片与折叠态实时日志、Diff 红绿高亮、原生图片 Zoom 预览、触觉反馈、iPhone Duo 折叠屏适配与灵动岛实时活动。

## 快速开始

### 1. 在 Mac 启动网关（直连模式，零服务器配置）

确保本机已安装并登录 `agy`（Node.js >= 22）：

```sh
npm --prefix gateway install
AGY_CWD="$PWD" npm --prefix gateway start
```

终端会自动打印 **Tailscale 直连** 和 **局域网直连** 的配对二维码与链接（端口默认 `8790`）。打开手机上的 **Agy Mobile** 扫码即可配对连接。

### 2. 可选：启用自托管公网 Relay（出门 5G 随时连）

在 VPS 上启动 `relay`（监听 `127.0.0.1:8791`，由 Caddy / Nginx 代理 `/agy/*`）：

```sh
export GATEWAY_TOKEN='<32字节以上随机令牌>'
npm --prefix relay install
npm --prefix relay start
```

然后在 Mac 网关同时配置 `RELAY_URL`、`PAIR_BASE` 和相同的 `GATEWAY_TOKEN`（默认会与本地直连并行运行）：

```sh
export RELAY_URL='wss://relay.example.com/agy/gateway'
export PAIR_BASE='https://relay.example.com/agy/pair'
export GATEWAY_TOKEN='<同上>'
export AGY_CWD="$PWD"
npm --prefix gateway start
```

### 3. 从源码构建 iOS App

```sh
(cd app && xcodegen generate && open AgyMobile.xcodeproj)
```

运行全部测试：

```sh
npm --prefix relay test
npm --prefix gateway test
swift test --package-path app/Packages/AgyMobileCore
```
