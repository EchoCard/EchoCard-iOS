import SwiftUI
import AVFoundation

/// 扫码登录桌面端 — 扫描 EchoCard Desktop 二维码建立局域网连接
struct DesktopQRScanView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var link = DesktopLinkService.shared
    @State private var scannedCode: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var cameraAuthorized = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                if cameraAuthorized {
                    QRScannerRepresentable(onCodeScanned: handleScanned)
                        .ignoresSafeArea()
                    
                    scanOverlay
                } else {
                    cameraPermissionView
                }
                
                if link.status == .connecting {
                    connectingOverlay
                }
            }
            .navigationTitle("扫码登录桌面端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                checkCameraPermission()
            }
            .onChange(of: link.status) { _, newStatus in
                if case .connected = newStatus {
                    dismiss()
                }
                if case .failed(let msg) = newStatus {
                    errorMessage = msg
                    showError = true
                }
            }
            .alert("连接失败", isPresented: $showError) {
                Button("重试") { scannedCode = nil }
                Button("取消", role: .cancel) { dismiss() }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var scanOverlay: some View {
        VStack(spacing: 24) {
            Spacer()
            
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.8), lineWidth: 3)
                .frame(width: 260, height: 260)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial.opacity(0.1))
                )
            
            VStack(spacing: 8) {
                Text("将桌面端二维码放入框内")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                
                Text("确保手机与电脑在同一局域网")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 40)
            
            Spacer()
            Spacer()
        }
    }
    
    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
                Text("正在连接...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    
    private var cameraPermissionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            
            Text("需要相机权限")
                .font(.system(size: 20, weight: .semibold))
            
            Text("请在设置中允许 EchoCard 使用相机来扫描桌面端二维码")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button("前往设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { cameraAuthorized = granted }
            }
        default:
            cameraAuthorized = false
        }
    }
    
    private func handleScanned(_ code: String) {
        guard scannedCode == nil else { return }
        scannedCode = code
        
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        link.connect(qrPayload: code)
    }
}

// MARK: - AVFoundation QR Scanner

struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    
    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }
    
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        
        hasScanned = true
        session.stopRunning()
        onCodeScanned?(value)
    }
}
