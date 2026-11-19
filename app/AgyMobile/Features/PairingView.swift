import SwiftUI
import AVFoundation
import UIKit

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token = ""
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Theme.background()
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: 40)
                    ZStack {
                        Circle()
                            .fill(Theme.indigo.opacity(0.28))
                            .frame(width: 108, height: 108)
                            .blur(radius: 18)
                        AgyMark(size: 76)
                    }
                    Text("连接 Antigravity")
                        .appFont(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("直接扫描 Antigravity 桌面端「Remote Control」二维码，或扫描自建网关二维码（原生界面 · 支持局域网 / Tailscale 直连与公网 Relay）。")
                        .appFont(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    VStack(spacing: 14) {
                        Button {
                            AgyHaptics.tap()
                            showScanner = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "qrcode.viewfinder")
                                    .appFont(.system(size: 18, weight: .semibold))
                                Text("扫描配对二维码")
                                    .appFont(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(bouncy())

                        HStack(spacing: 10) {
                            TextField("粘贴官方远程链接或网关配对链接", text: $token)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Theme.textPrimary)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .agyGlassCard(radius: 16)
                            Button("连接") {
                                AgyHaptics.tap()
                                model.pair(token: token)
                            }
                            .appFont(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .agyGlassCard(radius: 16, tint: Theme.indigo.opacity(0.32), interactive: true)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(18)
                    .agyGlassCard(radius: 24)

                    if let error = model.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                            Spacer()
                            Button { model.clearError() } label: {
                                Image(systemName: "xmark")
                            }
                        }
                        .appFont(.footnote)
                        .foregroundStyle(Theme.coral)
                        .padding(12)
                        .agyGlassCard(radius: 16, tint: Theme.coral.opacity(0.12))
                        .transition(AgyMotion.bannerTransition)
                    }
                    Spacer(minLength: 40)
                }
                .animation(AgyMotion.smooth(reduceMotion), value: model.errorMessage)
                .padding(24)
            }
        }
        .sheet(isPresented: $showScanner) {
            PairScanner { code in
                showScanner = false
                token = code
                model.pair(token: code)
            }
        }
    }
}

struct PairScanner: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanProgress: CGFloat = 0

    var body: some View {
        ZStack {
            ScannerView(onFound: onFound)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("扫描配对二维码")
                        .appFont(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    AgyIconButton(systemName: "xmark") {
                        AgyHaptics.tap()
                        dismiss()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.black.opacity(0.18))
                    if !reduceMotion {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Theme.cyan.opacity(0.9), Theme.indigo.opacity(0.85), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2.5)
                            .shadow(color: Theme.cyan.opacity(0.8), radius: 6)
                            .offset(y: -110 + scanProgress * 220)
                    }
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Theme.mist.opacity(0.85), lineWidth: 2)
                }
                .frame(width: 260, height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                        scanProgress = 1
                    }
                }
                Spacer()
                Text("支持扫描桌面端 Antigravity 官方 Remote Control 二维码，或 agy-mobile 网关二维码。")
                    .appFont(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

private struct ScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private let statusLabel = UILabel()
    private var didFindCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupStatusLabel()
        startAfterPermissionCheck()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configurePreviewRotation(device: AVCaptureDevice, preview: AVCaptureVideoPreviewLayer) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }
    }

    private func setupStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .white
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.backgroundColor = UIColor(white: 0, alpha: 0.65)
        statusLabel.layer.cornerRadius = 12
        statusLabel.clipsToBounds = true
        statusLabel.isHidden = true
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func showStatus(_ text: String?) {
        guard let text, !text.isEmpty else {
            statusLabel.isHidden = true
            statusLabel.alpha = 0
            return
        }
        statusLabel.text = text
        statusLabel.isHidden = false
        statusLabel.alpha = 0
        UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 1 }
    }

    private func startAfterPermissionCheck() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            showStatus("正在请求相机权限…")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.startSession() }
                    else { self.showStatus("没有相机权限。请在系统设置中允许使用相机，或返回粘贴配对链接。") }
                }
            }
        case .denied, .restricted:
            showStatus("没有相机权限。请在系统设置中允许使用相机，或返回粘贴配对链接。")
        @unknown default:
            showStatus("无法使用相机，请返回粘贴配对链接。")
        }
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            showStatus("此设备没有可用的摄像头，请返回粘贴配对链接。")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                showStatus("无法启用摄像头，请返回粘贴配对链接。")
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                showStatus("无法启用二维码识别，请返回粘贴配对链接。")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            configurePreviewRotation(device: device, preview: preview)

            output.setMetadataObjectsDelegate(self, queue: .main)
            session.startRunning()

            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.stopRunning()
                showStatus("此设备不支持二维码识别，请返回粘贴配对链接。")
                return
            }
            output.metadataObjectTypes = [.qr]
            showStatus(nil)
        } catch {
            showStatus("摄像头初始化失败：\(error.localizedDescription)")
        }
    }

    func stopSession() {
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didFindCode,
              let object = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else { return }
        didFindCode = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        stopSession()
        onFound?(value)
    }
}
