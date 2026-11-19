import SwiftUI
import AgyMobileCore

@main
struct AgyMobileApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var scrollStore = ConversationScrollStore()
    @Environment(\.scenePhase) private var phase
    @AppStorage(AgyInterfaceStyle.key) private var interfaceStyle = AgyInterfaceStyle.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isPaired {
                    AgyRootView()
                } else if let remote = model.officialRemote {
                    OfficialRemoteHomeView(remote: remote)
                } else {
                    PairingView()
                        .environment(\.colorScheme, .dark)
                }
            }
            .modifier(AppFontScope())
            .environmentObject(model)
            .environmentObject(scrollStore)
            .preferredColorScheme((AgyInterfaceStyle(rawValue: interfaceStyle) ?? .system).colorScheme)
            .onAppear { model.bootstrap() }
            .onChange(of: phase) { _, newValue in
                if newValue == .active { model.resume() }
                if newValue == .background { model.suspendConnectionChecks() }
            }
        }
    }
}
