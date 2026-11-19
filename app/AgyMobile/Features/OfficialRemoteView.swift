import SafariServices
import SwiftUI
import UIKit
import AgyMobileCore

struct OfficialRemoteHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let remote: OfficialRemoteLink
    @State private var showsSafari = false
    @State private var showsScanner = false
    @State private var showsRemoveConfirm = false
    @State private var hasUsedInitialLaunch = false

    private var activeURL: URL {
        hasUsedInitialLaunch ? remote.targetURL : remote.launchURL
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background()
                ScrollView {
                    VStack(spacing: 22) {
                        Spacer(minLength: 28)

                        ZStack {
                            Circle()
                                .fill(Theme.indigo.opacity(0.24))
                                .frame(width: 108, height: 108)
                                .blur(radius: 18)
                            AgyMark(size: 72)
                        }

                        VStack(spacing: 6) {
                            Text("Antigravity 官方远程")
                                .appFont(.title2.bold())
                                .foregroundStyle(Theme.textPrimary)
                            Text("直接连接你 Mac 桌面端 Antigravity 的 Remote Control，共享本机 Safari Google 登录态。")
                                .appFont(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 18)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                StatusDot(color: Theme.success, size: 8, pulsing: true)
                                Text("已绑定桌面端设备")
                                    .appFont(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("官方远程")
                                    .appFont(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.indigo)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Theme.indigo.opacity(0.14), in: Capsule())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(remote.deviceID)
                                    .appFont(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(remote.targetURL.host ?? "antigravity.google.com")
                                    .appFont(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Button {
                                AgyHaptics.tap()
                                showsSafari = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .appFont(.subheadline.weight(.semibold))
                                    Text("打开 Remote Control")
                                        .appFont(.headline)
                                }
                                .foregroundStyle(Theme.onAccent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(bouncy())
                        }
                        .padding(18)
                        .agyGlassCard(radius: 24)

                        VStack(spacing: 10) {
                            Button {
                                AgyHaptics.tap()
                                showsScanner = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .foregroundStyle(Theme.indigo)
                                    Text("重新扫码（官方码或自建网关原生模式）")
                                        .appFont(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .appFont(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 50)
                                .agyGlassCard(radius: 16, interactive: true)
                            }
                            .buttonStyle(bouncy())

                            Button {
                                AgyHaptics.tap()
                                openURL(activeURL)
                                hasUsedInitialLaunch = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "safari")
                                        .foregroundStyle(Theme.indigo)
                                    Text("在系统 Safari 中打开")
                                        .appFont(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .appFont(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 50)
                                .agyGlassCard(radius: 16, interactive: true)
                            }
                            .buttonStyle(bouncy())

                            Button(role: .destructive) {
                                AgyHaptics.tap()
                                showsRemoveConfirm = true
                            } label: {
                                Text("移除此设备")
                                    .appFont(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.coral)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(bouncy())
                            .padding(.top, 4)
                        }

                        Spacer(minLength: 24)
                    }
                    .padding(22)
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            if model.shouldPresentOfficialRemote {
                model.shouldPresentOfficialRemote = false
                showsSafari = true
            }
        }
        .onChange(of: model.shouldPresentOfficialRemote) { _, requested in
            if requested {
                model.shouldPresentOfficialRemote = false
                showsSafari = true
            }
        }
        .fullScreenCover(isPresented: $showsSafari, onDismiss: {
            hasUsedInitialLaunch = true
        }) {
            OfficialRemoteSafariSheet(url: activeURL)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showsScanner) {
            PairScanner { code in
                showsScanner = false
                hasUsedInitialLaunch = false
                model.pair(token: code)
            }
        }
        .confirmationDialog("移除已绑定的官方远程设备？", isPresented: $showsRemoveConfirm, titleVisibility: .visible) {
            Button("移除", role: .destructive) { model.clearOfficialRemote() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后将返回扫码页，你可以随时重新扫描桌面端或自建网关二维码。")
        }
    }
}

struct OfficialRemoteSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = UIColor(Theme.indigo)
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
