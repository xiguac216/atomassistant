import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var appear = false
    @State private var showScanner = false
    @State private var showManual = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var manualServer = ""
    @State private var manualCode = ""

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "atom")
                        .font(.system(size: 76, weight: .light))
                        .foregroundStyle(.white)
                        .frame(width: 132, height: 132)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 24, y: 12)
                        .scaleEffect(appear ? 1 : 0.6)
                        .opacity(appear ? 1 : 0)
                    VStack(spacing: 8) {
                        Text("原子助手")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("让助手看见只有手机才有的信息：\n运动、健康、系统状态……\n数据只会发给你自己的服务器。")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .offset(y: appear ? 0 : 16)
                    .opacity(appear ? 1 : 0)
                }
                Spacer()
                VStack(spacing: 12) {
                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Button {
                        Haptics.tap()
                        showScanner = true
                    } label: {
                        Label("扫码配对", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        Haptics.tap()
                        showManual = true
                    } label: {
                        Text("手动输入配对码")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Text("在原子助手后台的「手机」页添加设备，会得到二维码和配对码。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .offset(y: appear ? 0 : 30)
                .opacity(appear ? 1 : 0)
            }
            if busy {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView("正在配对…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: errorText)
        .animation(.easeOut(duration: 0.2), value: busy)
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { appear = true } }
        .sheet(isPresented: $showScanner) {
            ScannerSheet { text in
                showScanner = false
                guard let url = URL(string: text) else { errorText = "这个二维码不是原子助手的配对码"; Haptics.error(); return }
                model.handle(url: url)
                if model.incomingPairing == nil { errorText = "这个二维码不是原子助手的配对码"; Haptics.error() }
            }
        }
        .sheet(isPresented: $showManual) {
            manualSheet
        }
        .onChange(of: model.incomingPairing?.code) { _ in
            guard let p = model.incomingPairing else { return }
            model.incomingPairing = nil
            Task { await doPair(server: p.server, code: p.code) }
        }
        .onAppear {
            // 点链接冷启动进来时，链接可能先于这个视图到达。
            if let p = model.incomingPairing {
                model.incomingPairing = nil
                Task { await doPair(server: p.server, code: p.code) }
            }
        }
    }

    private var background: some View {
        ZStack {
            Color(.systemGroupedBackground)
            Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 320).blur(radius: 70).offset(x: -120, y: -260)
            Circle().fill(Color.purple.opacity(0.12)).frame(width: 280).blur(radius: 70).offset(x: 140, y: -120)
        }
        .ignoresSafeArea()
    }

    private var manualSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://你的域名", text: $manualServer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("配对码，如 K7M2-9XQP", text: $manualCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("服务器地址和配对码都在后台「手机」页添加设备后显示，配对码十分钟内有效。")
                }
            }
            .navigationTitle("手动配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showManual = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("配对") {
                        showManual = false
                        Task { await doPair(server: manualServer, code: manualCode) }
                    }
                    .disabled(manualServer.isEmpty || manualCode.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func doPair(server: String, code: String) async {
        errorText = nil
        busy = true
        defer { busy = false }
        do {
            try await model.pair(server: server, code: code)
            Haptics.success()
        } catch {
            Haptics.error()
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 扫码

struct ScannerSheet: View {
    let onCode: (String) -> Void
    @State private var denied = false

    var body: some View {
        ZStack(alignment: .top) {
            if denied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("没有相机权限").font(.headline)
                    Text("请到 设置 → 原子助手 里打开相机，或者改用手动输入配对码。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScannerView(onCode: onCode, onDenied: { denied = true })
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .frame(maxHeight: .infinity)
                Text("对准后台显示的二维码")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 24)
            }
        }
    }
}

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        c.onDenied = onDenied
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onDenied: (() -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.setup() : self.onDenied?() }
            }
        default: onDenied?()
        }
    }

    private func setup() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            onDenied?()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onDenied?(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled, let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let text = obj.stringValue else { return }
        handled = true
        Haptics.success()
        onCode?(text)
    }
}
