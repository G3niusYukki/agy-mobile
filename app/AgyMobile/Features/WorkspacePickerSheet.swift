import SwiftUI
import AgyMobileCore

struct WorkspacePickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onSelect: (String?) -> Void

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [AgyWorkspaceOption] {
        let all = model.effectiveWorkspaces
        guard !trimmedQuery.isEmpty else { return all }
        return all.filter {
            $0.name.localizedStandardContains(trimmedQuery)
                || $0.displayPath.localizedStandardContains(trimmedQuery)
                || $0.path.localizedStandardContains(trimmedQuery)
        }
    }

    private var recentWorkspaces: [AgyWorkspaceOption] {
        filtered.filter(\.isRecentGroup)
    }

    private var projectWorkspaces: [AgyWorkspaceOption] {
        filtered.filter { !$0.isRecentGroup }
    }

    private var customPathCandidate: String? {
        guard trimmedQuery.hasPrefix("/") || trimmedQuery.hasPrefix("~") else { return nil }
        let existsInList = filtered.contains {
            $0.path == trimmedQuery || $0.displayPath == trimmedQuery
        }
        return existsInList ? nil : trimmedQuery
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AgySearchField(text: $query, placeholder: "搜索工作区或输入路径（如 ~/my-app）")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let custom = customPathCandidate {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("自定义路径")
                                customPathRow(custom)
                            }
                        }

                        if !recentWorkspaces.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("最近工作区")
                                workspaceCard(recentWorkspaces)
                            }
                        }

                        if !projectWorkspaces.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionHeader("本机项目")
                                workspaceCard(projectWorkspaces)
                            }
                        }

                        if recentWorkspaces.isEmpty && projectWorkspaces.isEmpty && customPathCandidate == nil {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("选择工作区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        AgyHaptics.tap()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        AgyHaptics.tap()
                        model.loadWorkspaces()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .appFont(.system(size: 15, weight: .semibold))
                    }
                    .disabled(!model.isConnected || model.isLoadingWorkspaces)
                    .accessibilityLabel("刷新工作区")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { model.loadWorkspaces() }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .appFont(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func workspaceCard(_ items: [AgyWorkspaceOption]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, workspace in
                workspaceRow(workspace)
                if index + 1 < items.count {
                    Divider().padding(.leading, 58)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func workspaceRow(_ workspace: AgyWorkspaceOption) -> some View {
        let isCurrent = model.currentCwd == workspace.path
        return Button {
            AgyHaptics.selection()
            dismiss()
            onSelect(workspace.path)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(for: workspace))
                    .appFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? Theme.onAccent : Theme.indigo)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isCurrent ? Theme.accent : Theme.cardFillStrong)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .appFont(.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isCurrent {
                            badge("当前", highlighted: true)
                        } else if workspace.isDefault {
                            badge("默认", highlighted: false)
                        }
                    }
                    Text(workspace.displayPath)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if workspace.sessionCount > 0 {
                    Text("\(workspace.sessionCount) 会话")
                        .appFont(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .appFont(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace-option-\(workspace.name)")
    }

    private func customPathRow(_ path: String) -> some View {
        Button {
            AgyHaptics.selection()
            dismiss()
            onSelect(path)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .appFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用指定目录新建会话")
                        .appFont(.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(path)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .appFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if model.isLoadingWorkspaces {
                AgyShimmerText(text: "正在读取 Mac 工作区…", font: .subheadline.weight(.medium))
                    .padding(.top, 20)
            } else {
                Text(trimmedQuery.isEmpty ? "暂未发现本机工作区" : "没有匹配的工作区")
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            }

            Button {
                AgyHaptics.selection()
                dismiss()
                onSelect(nil)
            } label: {
                Text("使用默认工作区新建会话")
                    .appFont(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(bouncy())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func iconName(for workspace: AgyWorkspaceOption) -> String {
        if workspace.source == .pinned { return "pin.fill" }
        if workspace.displayPath == "~" { return "house.fill" }
        return "folder.fill"
    }

    private func badge(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .appFont(.caption2.weight(.semibold))
            .foregroundStyle(highlighted ? Theme.indigo : Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(highlighted ? Theme.indigo.opacity(0.12) : Theme.cardFillStrong)
            )
    }
}
