import SwiftUI
import AgyMobileCore

enum ConversationTab: Hashable {
    case chat, trace

    enum Row: Identifiable {
        case message(ChatMessage), tools(ToolStepGroup)

        var id: UUID {
            switch self {
            case .message(let message): message.id
            case .tools(let group): group.id
            }
        }
    }

    func rows(in messages: [ChatMessage]) -> [Row] {
        var rows: [Row] = []
        var steps: [ChatMessage] = []
        func flush() {
            guard !steps.isEmpty else { return }
            rows.append(.tools(ToolStepGroup(steps: steps)))
            steps.removeAll(keepingCapacity: true)
        }
        for message in messages {
            if message.role == .tool {
                steps.append(message)
                if self == .trace { flush() }
            } else if self == .chat, !message.text.isEmpty || !message.attachments.isEmpty {
                flush()
                rows.append(.message(message))
            }
        }
        flush()
        return rows
    }

    static func activityLabel(in messages: [ChatMessage], connection: ConnectionState, phase: RunPhase) -> String? {
        guard connection == .running, !messages.contains(where: { $0.role == .tool && $0.toolStatus == .running }) else { return nil }
        switch phase {
        case .thinking: return "正在思考…"
        case .preparingTool: return "正在准备工具…"
        case .replying: return nil
        case .waiting: return "等待回复…"
        }
    }
}

struct ToolStepGroup: Identifiable {
    let steps: [ChatMessage]
    var id: UUID { steps[0].id }
    var running: [ChatMessage] { steps.filter { $0.toolStatus == .running } }
    var failed: Int { steps.filter { $0.toolStatus == .failed }.count }
    var unconfirmed: Int { steps.filter { $0.toolStatus == .unconfirmed }.count }

    var headline: String {
        if let current = running.last { return "正在\(Self.name(current))" }
        if steps.count == 1 { return Self.name(steps[0]) }
        return "\(steps.count) 个工具步骤"
    }

    var detail: String {
        if !running.isEmpty {
            if steps.count == 1 { return running[0].toolUpdates > 0 ? "已更新 \(running[0].toolUpdates) 次" : "执行中" }
            let complete = steps.count - running.count - unconfirmed
            return "\(complete)/\(steps.count) 已完成"
        }
        if failed > 0 { return steps.count == 1 ? "失败" : "\(failed) 个失败" }
        if unconfirmed > 0 { return "结果待确认" }
        return "已完成"
    }

    static func name(_ message: ChatMessage) -> String {
        let raw = message.toolTitle?.lowercased() ?? ""
        if raw.hasPrefix("browser_") { return "操作浏览器" }
        switch raw {
        case "view_file", "read_file", "read": return "读取文件"
        case "write_to_file", "write_file", "write": return "写入文件"
        case "replace_file_content", "multi_replace_file_content", "edit_file", "sed_file", "edit": return "编辑文件"
        case "run_command", "bash": return "运行命令"
        case "grep_search", "grep": return "搜索内容"
        case "find_by_name", "find": return "查找文件"
        case "list_dir", "ls": return "查看目录"
        case "search_web", "read_url_content": return "联网检索"
        case "invoke_subagent", "run_workflow": return "调用子代理"
        case "call_mcp_tool": return "调用 MCP"
        default: return message.toolTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "调用工具"
        }
    }

    static func symbol(for message: ChatMessage) -> String {
        let raw = message.toolTitle?.lowercased() ?? ""
        if raw.hasPrefix("browser_") { return "safari" }
        switch raw {
        case "view_file", "read_file", "read": return "doc.text"
        case "write_to_file", "write_file", "write": return "doc.badge.plus"
        case "replace_file_content", "multi_replace_file_content", "edit_file", "sed_file", "edit": return "pencil.line"
        case "run_command", "bash": return "terminal"
        case "grep_search", "grep": return "magnifyingglass"
        case "find_by_name", "find": return "doc.text.magnifyingglass"
        case "list_dir", "ls": return "folder"
        case "search_web", "read_url_content": return "globe"
        case "invoke_subagent", "run_workflow": return "sparkles"
        case "call_mcp_tool": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }

    var activeToolSymbol: String {
        if let current = running.last { return Self.symbol(for: current) }
        if steps.count == 1 { return Self.symbol(for: steps[0]) }
        return "wrench.and.screwdriver"
    }

    var livePreviewText: String? {
        guard let raw = running.last?.text else { return nil }
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(2).joined(separator: "\n")
    }
}

struct ToolActivityRow: View {
    let group: ToolStepGroup
    let showsOutput: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private var isRunning: Bool { !group.running.isEmpty }
    private var isOpen: Bool { showsOutput ? !expanded : expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                AgyHaptics.selection()
                withAnimation(AgyMotion.smooth(reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 18, height: 18)

                    if isRunning {
                        AgyShimmerText(text: group.headline, font: .subheadline.weight(.medium))
                            .lineLimit(1)
                    } else {
                        Text(group.headline)
                            .appFont(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Text(group.detail)
                        .appFont(.caption)
                        .foregroundStyle(detailColor)
                        .contentTransition(.numericText())
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .appFont(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(AgyMotion.snappy(reduceMotion), value: isOpen)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "已展开" : "已收起")
            .accessibilityHint(isOpen ? "收起工具详情" : "展开查看每步状态和输出")

            if !isOpen, isRunning, let preview = group.livePreviewText {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Theme.indigo.opacity(0.45))
                        .frame(width: 2)
                        .padding(.vertical, 2)
                        .padding(.leading, 8)
                    Text(preview)
                        .appFont(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.steps) { step in
                        ToolStepDetailView(step: step)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
                .transition(AgyMotion.disclosureTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isRunning ? Theme.indigo.opacity(0.065) : Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isRunning ? Theme.indigo.opacity(0.28)
                        : (group.failed > 0 ? Theme.amber.opacity(0.35) : Theme.cardStroke.opacity(0.55)),
                    lineWidth: 0.75
                )
        )
        .clipped()
        .animation(AgyMotion.smooth(reduceMotion), value: isRunning)
        .animation(AgyMotion.smooth(reduceMotion), value: isOpen)
    }

    private var detailColor: Color {
        if isRunning { return Theme.indigo }
        if group.failed > 0 { return Theme.amber }
        return .secondary
    }

    @ViewBuilder private var statusIcon: some View {
        Group {
            if isRunning {
                Image(systemName: group.activeToolSymbol)
                    .appFont(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.indigo)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            } else if group.failed > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .appFont(.system(size: 14))
                    .foregroundStyle(Theme.amber)
            } else if group.unconfirmed > 0 {
                Image(systemName: "questionmark.circle")
                    .appFont(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .appFont(.system(size: 14))
                    .foregroundStyle(Theme.success.opacity(0.85))
            }
        }
        .contentTransition(.symbolEffect(.replace))
    }

    static func detail(_ step: ChatMessage) -> String {
        let state: String
        switch step.toolStatus {
        case .running: state = step.toolUpdates == 0 ? "执行中" : "执行中 · 已更新 \(step.toolUpdates) 次"
        case .finished: state = "已完成"
        case .failed: state = "失败"
        case .unconfirmed: state = "结果待确认"
        }
        guard let ms = step.toolDurationMs else { return state }
        if ms < 1000 { return "\(state) · \(ms) 毫秒" }
        let seconds = (Double(ms) / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return "\(state) · \(seconds) 秒"
    }
}

private struct ToolStepDetailView: View {
    let step: ChatMessage

    private var isDiffOutput: Bool {
        let lines = step.text.components(separatedBy: "\n")
        return lines.contains { $0.hasPrefix("@@ ") }
            || (lines.contains { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
                && lines.contains { $0.hasPrefix("-") && !$0.hasPrefix("---") })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 4) {
                stepBadge
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)
                Rectangle()
                    .fill(Theme.cardStroke.opacity(0.6))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: ToolStepGroup.symbol(for: step))
                        .appFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(step.toolTitle ?? "工具")
                        .appFont(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(ToolActivityRow.detail(step))
                        .appFont(.caption)
                        .foregroundStyle(step.toolStatus == .failed ? Theme.amber : .secondary)
                        .contentTransition(.numericText())
                }

                if !step.text.isEmpty {
                    Group {
                        if isDiffOutput {
                            ScrollView(.horizontal, showsIndicators: false) {
                                DiffCodeContent(code: step.text)
                                    .padding(.vertical, 6)
                            }
                            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text(step.text)
                                .textSelection(.enabled)
                                .appFont(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contextMenu {
                        Button("复制工具输出", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = step.text
                            AgyHaptics.success()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var stepBadge: some View {
        switch step.toolStatus {
        case .running:
            StatusDot(color: Theme.indigo, size: 7, pulsing: true)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .appFont(.system(size: 11))
                .foregroundStyle(Theme.success.opacity(0.85))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .appFont(.system(size: 11))
                .foregroundStyle(Theme.amber)
        case .unconfirmed:
            Image(systemName: "questionmark.circle")
                .appFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
