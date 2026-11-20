import XCTest
import SwiftUI
import AgyMobileCore
@testable import AgyMobile

@MainActor
final class AgyMobileTests: XCTestCase {
    private var window: UIWindow?
    private var previousWindow: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousWindow?.makeKey()
        previousWindow = nil
        super.tearDown()
    }

    func testAntigravityToolMappingsAndLivePreview() {
        let cmd = ChatMessage(role: .tool, text: "echo hi\nhi", toolTitle: "run_command", toolStatus: .running)
        let view = ChatMessage(role: .tool, text: "", toolTitle: "view_file", toolStatus: .finished)
        let edit = ChatMessage(role: .tool, text: "", toolTitle: "replace_file_content", toolStatus: .finished)
        let browser = ChatMessage(role: .tool, text: "", toolTitle: "browser_click_element", toolStatus: .finished)

        XCTAssertEqual(ToolStepGroup.name(cmd), "运行命令")
        XCTAssertEqual(ToolStepGroup.symbol(for: cmd), "terminal")
        XCTAssertEqual(ToolStepGroup.name(view), "读取文件")
        XCTAssertEqual(ToolStepGroup.symbol(for: view), "doc.text")
        XCTAssertEqual(ToolStepGroup.name(edit), "编辑文件")
        XCTAssertEqual(ToolStepGroup.symbol(for: edit), "pencil.line")
        XCTAssertEqual(ToolStepGroup.name(browser), "操作浏览器")
        XCTAssertEqual(ToolStepGroup.symbol(for: browser), "safari")

        let group = ToolStepGroup(steps: [view, cmd])
        XCTAssertEqual(group.headline, "正在运行命令")
        XCTAssertEqual(group.detail, "1/2 已完成")
        XCTAssertEqual(group.livePreviewText, "echo hi\nhi")
        XCTAssertNil(AgyMotion.quickFade(true))
    }

    func testEffortAndModeChoices() {
        XCTAssertEqual(AgyEffortLevel.choices, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(AgyEffortLevel.title("xhigh"), "极高")
        XCTAssertEqual(AgentMode.plan.title, "规划模式")
    }

    func testRenderAntigravityScreens() async throws {
        let model = AppModel()
        try? await Task.sleep(for: .milliseconds(250))
        model.connection = .running
        model.selectedSessionPath = "11111111-2222-4333-8444-555555555555"
        model.selectedSessionTitle = "优化液态玻璃动效"
        model.models = [
            ModelOption(provider: "Google", modelId: "gemini-4-neon-xhigh", displayName: "Gemini 4 Neon (XHigh)"),
            ModelOption(provider: "Anthropic", modelId: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"),
        ]
        model.selectedModel = model.models[0].id
        model.thinking = "xhigh"
        model.agentMode = .plan
        model.currentCwd = "/projects/agy-mobile"
        model.workspaces = [
            AgyWorkspaceOption(path: "/projects/agy-mobile", name: "agy-mobile", displayPath: "~/agy-mobile", sessionCount: 2, source: .recent),
            AgyWorkspaceOption(path: "/projects/pi-mobile", name: "pi-mobile", displayPath: "~/pi-mobile", sessionCount: 1, source: .recent),
            AgyWorkspaceOption(path: "/projects/zcode-mobile", name: "zcode-mobile", displayPath: "~/zcode-mobile", sessionCount: 0, source: .project),
        ]
        XCTAssertEqual(model.currentWorkspaceName, "agy-mobile")
        XCTAssertEqual(model.currentWorkspaceDisplayPath, "~/agy-mobile")
        let now = Date().timeIntervalSince1970 * 1_000
        model.sessions = [
            ["path": "11111111-2222-4333-8444-555555555555", "title": "优化液态玻璃动效", "cwd": "/projects/agy-mobile", "summary": "接入 iOS 26 GlassEffectContainer 与工具预览。", "mtime": now - 120_000],
            ["path": "22222222-3333-4444-8555-666666666666", "title": "排查网关断线重连", "cwd": "/projects/agy-mobile", "summary": "支持局域网与 Tailscale 直连。", "mtime": now - 3_600_000],
        ]
        model.messages = [
            ChatMessage(role: .user, text: "帮我检查一下 gateway 测试是否全部通过？"),
            ChatMessage(role: .tool, text: "npm --prefix gateway test\n✔ 3/3 passed", toolTitle: "run_command", toolStatus: .finished),
            ChatMessage(role: .assistant, text: "全部 **3 项测试通过**，直连配对与 E2E 加密正常。\n\n```diff\n- oldStatus\n+ StatusDot(color: Theme.indigo, pulsing: true)\n```"),
            ChatMessage(role: .tool, text: "正在扫描最近改动文件…", toolTitle: "grep_search", toolStatus: .running),
        ]

        let store = ConversationScrollStore()
        let narrow = CGSize(width: 390, height: 844)
        try await snapshot("agy-workspace-light", size: narrow, style: .light, model: model, store: store) {
            SessionsPane(onSettings: {})
        }
        try await snapshot("agy-conversation-dark", size: narrow, style: .dark, model: model, store: store) {
            ConversationScreen(onSettings: {})
        }
        try await snapshot("agy-settings-light", size: narrow, style: .light, model: model, store: store) {
            AgySettingsView(open: { _ in })
        }
        try await snapshot("agy-workspace-picker-dark", size: narrow, style: .dark, model: model, store: store) {
            WorkspacePickerSheet { _ in }
        }
    }

    private func snapshot<Content: View>(_ name: String, size: CGSize, style: UIUserInterfaceStyle,
                                         model: AppModel, store: ConversationScrollStore,
                                         @ViewBuilder content: () -> Content) async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if previousWindow == nil { previousWindow = scene.windows.first(where: \.isKeyWindow) }
        let w = UIWindow(windowScene: scene)
        w.frame = CGRect(origin: .zero, size: size)
        w.overrideUserInterfaceStyle = style
        w.rootViewController = UIHostingController(rootView: NavigationStack { content() }
            .modifier(AppFontScope()).environmentObject(model).environmentObject(store))
        w.makeKeyAndVisible()
        self.window = w
        try? await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
