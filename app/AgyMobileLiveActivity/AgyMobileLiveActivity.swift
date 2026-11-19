import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AgyMobileLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AgyMobileLiveActivityWidget()
    }
}

struct AgyMobileLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenCard(context: context)
                .activityBackgroundTint(Color.black.opacity(0.9))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        AgyBadge(size: 26)
                        Text(context.state.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 5) {
                        Image(systemName: context.state.phase.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(phaseColor(context.state.phase))
                            .symbolEffect(.pulse, isActive: context.state.phase == .running)
                        ElapsedText(since: context.attributes.startedAt)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StatusPill(phase: context.state.phase,
                                       approvalCount: context.state.approvalCount)
                            if let tool = context.state.lastToolName, !tool.isEmpty {
                                Label(tool, systemImage: "wrench.and.screwdriver")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            Label(context.state.model, systemImage: "cpu")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                            Label(context.state.modeLabel, systemImage: "hand.raised")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                            Label(context.state.workspaceShort, systemImage: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                AgyBadge(size: 18)
            } compactTrailing: {
                HStack(spacing: 3) {
                    if context.state.approvalCount > 0 {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("\(context.state.approvalCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: context.state.phase.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(phaseColor(context.state.phase))
                            .symbolEffect(.pulse, isActive: context.state.phase == .running)
                    }
                }
            } minimal: {
                Image(systemName: context.state.phase.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(phaseColor(context.state.phase))
            }
            .keylineTint(phaseColor(context.state.phase))
        }
    }
}

// MARK: - 锁屏卡片

private struct LockScreenCard: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgyBadge(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(context.state.workspaceShort)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer()
                ElapsedText(since: context.attributes.startedAt)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            HStack(spacing: 8) {
                StatusPill(phase: context.state.phase,
                           approvalCount: context.state.approvalCount)
                if let tool = context.state.lastToolName, !tool.isEmpty {
                    Label(tool, systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Label(context.state.model, systemImage: "cpu")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Label(context.state.modeLabel, systemImage: "hand.raised")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(14)
    }
}

// MARK: - 小组件

private struct AgyBadge: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white)
            AgyLiveChevronShape()
                .fill(.black)
                .frame(width: size * 0.50, height: size * 0.56)
                .offset(y: -size * 0.01)
        }
        .frame(width: size, height: size)
    }
}

private struct AgyLiveChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX * 0.82, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.maxX * 0.18, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct StatusPill: View {
    let phase: SessionActivityPhase
    let approvalCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: phase.symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .symbolEffect(.pulse, isActive: phase == .running)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.16)))
    }

    private var text: String {
        if approvalCount > 0 { return "待审批 \(approvalCount)" }
        return phase.label
    }

    private var color: Color {
        switch phase {
        case .running: return .green
        case .awaitingApproval, .awaitingInput: return .orange
        case .idle: return .gray
        case .completed: return .green
        case .failed: return .red
        }
    }
}

private struct ElapsedText: View {
    let since: Date
    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .multilineTextAlignment(.trailing)
    }
}

private func phaseColor(_ phase: SessionActivityPhase) -> Color {
    switch phase {
    case .running: return .green
    case .awaitingApproval, .awaitingInput: return .orange
    case .idle: return .white.opacity(0.7)
    case .completed: return .green
    case .failed: return .red
    }
}
