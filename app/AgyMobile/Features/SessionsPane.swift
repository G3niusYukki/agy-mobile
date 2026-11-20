import SwiftUI
import AgyMobileCore

struct SessionsPane: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSettings: () -> Void
    @State private var searchText = ""
    @State private var showsWorkspacePicker = false
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        Group {
            if #available(iOS 27.1, *) {
                AgyWorkspaceToolbarLayout { vertical in
                    workspace(usesVerticalToolbar: vertical)
                } toolbar: {
                    ToolbarItem(placement: .topBarTrailing) {
                        connectionMenu(compactIcon: true)
                    }
                    .axisBehavior(.verticalPreferred)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("设置", systemImage: "gearshape") {
                            AgyHaptics.tap()
                            onSettings()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("workspace-settings")
                    }
                    .axisBehavior(.verticalPreferred)
                }
            } else {
                workspace(usesVerticalToolbar: false)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .buttonStyle(bouncy())
        .onAppear { model.loadSessions() }
        .sheet(isPresented: $showsWorkspacePicker) {
            WorkspacePickerSheet { cwd in
                model.newSession(cwd: cwd)
            }
        }
    }

    private func workspace(usesVerticalToolbar: Bool) -> some View {
        GeometryReader { geometry in
            let columns = AgyAdaptiveLayout.workspaceUsesColumns(
                size: geometry.size, accessibilityText: dynamicTypeSize.isAccessibilitySize
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        AgyWordmark()
                        if let kind = model.transportKind, !usesVerticalToolbar {
                            Text(kind.shortTitle)
                                .appFont(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.indigo)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.indigo.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        if !usesVerticalToolbar {
                            connectionMenu(compactIcon: false)
                            AgyIconButton(systemName: "gearshape") {
                                AgyHaptics.tap()
                                onSettings()
                            }
                            .accessibilityLabel("设置")
                            .accessibilityIdentifier("workspace-settings")
                        }
                    }
                    .padding(.bottom, 18)
                    if let gentle = model.gentleReconnectMessage {
                        gentleReconnectCard(text: gentle)
                            .padding(.bottom, 14)
                            .transition(AgyMotion.bannerTransition)
                    }
                    if columns {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 12) {
                                searchField
                                actionButtons(fullWidth: true)
                            }
                            .frame(width: min(260, geometry.size.width * 0.28), alignment: .leading)
                            Divider()
                            sessions(includesSearch: false).frame(maxWidth: .infinity)
                        }
                    } else {
                        workspaceActions
                        sessions(includesSearch: true).padding(.top, 20)
                    }
                }
                .padding(.horizontal, columns ? 40 : 22)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: AgyAdaptiveLayout.workspaceWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                AgyHaptics.tap()
                model.loadSessions()
            }
        }
        .background(Theme.background())
    }

    private var calmConnectedAppearance: Bool {
        model.isSilentlyReconnecting && model.hasConnectedOnce
    }

    private var connectionColor: Color {
        if calmConnectedAppearance { return Theme.success }
        if model.isReconnectingAfterGrace { return Theme.amber }
        switch model.connection {
        case .paired: return Theme.success
        case .running: return Theme.amber
        case .connecting: return Theme.indigo
        case .error: return Theme.coral
        case .idle: return .secondary
        }
    }

    private var connectionPulsing: Bool {
        if calmConnectedAppearance { return false }
        if model.isReconnectingAfterGrace { return true }
        return model.connection == .running || model.connection == .connecting
    }

    private func gentleReconnectCard(text: String) -> some View {
        HStack(spacing: 9) {
            StatusDot(color: Theme.amber, size: 7, pulsing: true)
            Text(text)
                .appFont(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("立即重试") {
                AgyHaptics.tap()
                model.reconnect()
            }
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(Theme.indigo)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke.opacity(0.6), lineWidth: 0.75)
        )
    }

    private func connectionMenu(compactIcon: Bool) -> some View {
        Menu {
            Label(
                model.transportKind.map { "\(statusText) · \($0.shortTitle)" } ?? statusText,
                systemImage: model.isConnected ? "lock.shield" : "wifi.slash"
            )
            if let host = model.endpointHost {
                Text(host)
            }
            Button("重新连接", systemImage: "arrow.clockwise") {
                AgyHaptics.tap()
                model.reconnect()
            }
            Button("刷新会话", systemImage: "arrow.triangle.2.circlepath") {
                AgyHaptics.tap()
                model.loadSessions()
            }
        } label: {
            if compactIcon {
                Image(systemName: model.isConnected ? "link" : "link.badge.plus")
                    .appFont(.system(size: 17, weight: .semibold))
                    .overlay(alignment: .topTrailing) {
                        StatusDot(color: connectionColor, size: 7, pulsing: connectionPulsing)
                            .offset(x: 4, y: -3)
                    }
                    .frame(width: 44, height: 44)
            } else {
                HStack(spacing: 7) {
                    StatusDot(color: connectionColor, size: 7, pulsing: connectionPulsing)
                    Text(statusText)
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .agyGlassCard(radius: 18, interactive: true)
                .animation(AgyMotion.quickFade(reduceMotion), value: statusText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("连接状态：\(statusText)")
    }

    private var hasCurrentSession: Bool {
        model.selectedSessionPath != nil || model.selectedSessionTitle != nil || !model.messages.isEmpty || !model.draft.isEmpty
    }

    private var workspaceActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons(fullWidth: true) }
            VStack(alignment: .leading, spacing: 10) { actionButtons(fullWidth: true) }
        }
    }

    private var canStartNewSession: Bool {
        (model.isConnected || calmConnectedAppearance) && !model.isLoadingHistory
    }

    @ViewBuilder private func actionButtons(fullWidth: Bool) -> some View {
        Button {
            AgyHaptics.tap()
            searchIsFocused = false
            showsWorkspacePicker = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .appFont(.subheadline.weight(.semibold))
                Text("新建会话")
                    .appFont(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(canStartNewSession ? 1 : 0.45)
        }
        .disabled(!canStartNewSession)
        .accessibilityIdentifier("workspace-new-session")

        if hasCurrentSession {
            Button {
                AgyHaptics.tap()
                searchIsFocused = false
                model.focusComposer = false
                model.showConversation = true
            } label: {
                HStack(spacing: 8) {
                    if model.connection == .running {
                        StatusDot(color: Theme.amber, size: 7, pulsing: true)
                    } else {
                        Image(systemName: "arrow.turn.down.right")
                            .appFont(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.indigo)
                    }
                    Text("继续会话")
                        .appFont(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 46)
                .agyGlassCard(radius: 16, interactive: true)
            }
            .accessibilityIdentifier("workspace-continue-session")
            .transition(AgyMotion.controlPopTransition)
        }
    }

    private var searchField: some View {
        AgySearchField(text: $searchText)
            .focused($searchIsFocused)
            .submitLabel(.search)
            .onSubmit { searchIsFocused = false }
    }

    private func sessions(includesSearch: Bool) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text("最近会话").appFont(.title2.bold()).accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12)
            if includesSearch { searchField }
            AgySessionList(searchText: searchText, onNewInWorkspace: { cwd in
                searchIsFocused = false
                model.newSession(cwd: cwd)
            }) { path in
                searchIsFocused = false
                model.switchSession(path)
            }
        }
    }

    private var statusText: String {
        if calmConnectedAppearance { return "已连接" }
        if model.isReconnectingAfterGrace {
            return model.reconnectPhase == .gatewayOfflineGentle ? "等待 Mac" : "重连中…"
        }
        switch model.connection {
        case .paired: return "已连接"
        case .running: return "执行中"
        case .connecting: return "连接中…"
        case .error: return "连接异常"
        case .idle: return "未连接"
        }
    }
}

struct AgySessionList: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let searchText: String
    var onNewInWorkspace: ((String) -> Void)? = nil
    let open: (String) -> Void

    var body: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = AgySessionFolder.grouped(model.sessions, matching: query)
        if folders.isEmpty {
            Text(query.isEmpty ? "暂无会话。连接 Mac 后开始第一个 Antigravity 任务。" : "没有匹配的会话。")
                .appFont(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        } else {
            ForEach(folders) { folder in
                Section {
                    ForEach(folder.entries) { entry in sessionRow(entry) }
                } header: {
                    folderHeader(folder)
                }
            }
        }
    }

    private func folderHeader(_ folder: AgySessionFolder) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).appFont(.subheadline.weight(.semibold))
                    if let parent = folder.parentPath {
                        Text(parent).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if let onNewInWorkspace, !folder.id.isEmpty,
               (model.isConnected || (model.isSilentlyReconnecting && model.hasConnectedOnce)) {
                Button {
                    AgyHaptics.tap()
                    onNewInWorkspace(folder.id)
                } label: {
                    Image(systemName: "plus")
                        .appFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.cardFill, in: Circle())
                }
                .buttonStyle(bouncy())
                .disabled(model.isLoadingHistory)
                .accessibilityLabel("在 \(folder.name) 新建会话")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }

    private func sessionRow(_ entry: AgySessionEntry) -> some View {
        let selected = model.selectedSessionPath == entry.path
        let isRunningHere = selected && model.connection == .running
        let largeType = dynamicTypeSize.isAccessibilitySize
        let heading = largeType ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return Button {
            AgyHaptics.selection()
            open(entry.path)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                heading {
                    HStack(alignment: .center, spacing: 7) {
                        if isRunningHere {
                            StatusDot(color: Theme.amber, size: 7, pulsing: true)
                                .accessibilityHidden(true)
                        } else if selected {
                            Image(systemName: "checkmark.circle.fill").appFont(.caption)
                                .foregroundStyle(Theme.indigo).accessibilityHidden(true)
                        }
                        Text(entry.title).appFont(.body.weight(.medium)).lineLimit(largeType ? nil : 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isRunningHere {
                        Text("工作中")
                            .appFont(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.amber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.amber.opacity(0.14), in: Capsule())
                    } else if let modified = entry.modified {
                        Text(modified, style: .relative).appFont(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = entry.summary {
                    Text(summary).appFont(.subheadline).foregroundStyle(.secondary).lineLimit(largeType ? nil : 2)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(bouncy())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .bottom) { Divider().accessibilityHidden(true) }
    }
}

@available(iOS 27.1, *)
private struct AgyWorkspaceToolbarLayout<Content: View, Toolbar: ToolbarContent>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ViewBuilder let content: (Bool) -> Content
    @ToolbarContentBuilder let toolbar: () -> Toolbar

    var body: some View {
        content(verticalEdge != nil)
            .toolbar { if verticalEdge != nil { toolbar() } }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
