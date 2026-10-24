import SwiftUI
import AVFoundation
import Vision

/// 카메라 기반 실시간 QR 코드 스캐너 뷰
public struct CameraScannerView: View {
    public let onCodeScanned: (String) -> Void
    
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined
    @State private var isCameraReady: Bool = false
    
    public init(onCodeScanned: @escaping (String) -> Void) {
        self.onCodeScanned = onCodeScanned
    }
    
    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch cameraPermission {
            case .authorized:
                PlatformCameraPreview(onCodeScanned: onCodeScanned)
                    .ignoresSafeArea()
                
                // 스캐너 가이드라인 오버레이
                ScannerOverlayView()
                
            case .notDetermined:
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                    Text("카메라 권한 확인 중...")
                        .foregroundStyle(.white)
                        .font(.subheadline)
                }
                .onAppear {
                    checkAndRequestPermission()
                }
                
            case .denied, .restricted:
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("카메라 접근 권한이 필요합니다")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("QR 코드를 스캔하기 위해 설정 앱에서 카메라 권한을 허용해주세요.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding()
                
            @unknown default:
                EmptyView()
            }
        }
        .onAppear {
            checkAndRequestPermission()
        }
    }
    
    private func checkAndRequestPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraPermission = status
        
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraPermission = granted ? .authorized : .denied
                }
            }
        }
    }
}

// MARK: - 스캐너 뷰파인더 애니메이션 오버레이

struct ScannerOverlayView: View {
    @State private var scanLineOffset: CGFloat = -120
    
    var body: some View {
        GeometryReader { geometry in
            let frameSize: CGFloat = min(geometry.size.width - 64, 320)
            
            ZStack {
                // 반투명 어두운 배경 + 뷰파인더 펀치홀
                Color.black.opacity(0.45)
                    .mask {
                        Rectangle()
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .frame(width: frameSize, height: frameSize)
                                    .blendMode(.destinationOut)
                            )
                    }
                    .ignoresSafeArea()
                
                // 뷰파인더 테두리
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 2)
                    .frame(width: frameSize, height: frameSize)
                    .overlay(
                        // 4 모서리 하이라이트
                        ZStack {
                            CornerGuide()
                                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .frame(width: frameSize, height: frameSize)
                            
                            // 스캔 레이저 애니메이션
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan.opacity(0), Color.cyan.opacity(0.8), Color.cyan.opacity(0)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: frameSize - 16, height: 3)
                                .offset(y: scanLineOffset)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                        }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    scanLineOffset = 120
                }
            }
        }
    }
}

// 뷰파인더 모서리 장식
struct CornerGuide: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let length: CGFloat = 28
        let r: CGFloat = 20
        
        // 좌상단
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        
        // 우상단
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        
        // 우하단
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        
        // 좌하단
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        
        return path
    }
}

// MARK: - Platform Camera Capture View

#if os(iOS)
struct PlatformCameraPreview: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

final class CameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }
    
    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              captureSession.canAddInput(videoInput) else {
            captureSession.commitConfiguration()
            return
        }
        
        captureSession.addInput(videoInput)
        
        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            }
        }
        
        captureSession.commitConfiguration()
        
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        self.previewLayer = layer
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for metadata in metadataObjects {
            guard let readableObject = metadata as? AVMetadataMachineReadableCodeObject,
                  readableObject.type == .qr,
                  let stringValue = readableObject.stringValue else {
                continue
            }
            onCodeScanned?(stringValue)
        }
    }
}

#elseif os(macOS)

struct PlatformCameraPreview: NSViewRepresentable {
    let onCodeScanned: (String) -> Void
    
    func makeNSView(context: Context) -> MacCameraContainerView {
        let view = MacCameraContainerView()
        view.onCodeScanned = onCodeScanned
        view.setupCaptureSession()
        return view
    }
    
    func updateNSView(_ nsView: MacCameraContainerView, context: Context) {}
}

final class MacCameraContainerView: NSView, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onCodeScanned: ((String) -> Void)?
    
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "camera.sample.queue", qos: .userInitiated)
    private var isProcessingFrame = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
    
    func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high
        
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }
        
        captureSession.addInput(input)
        
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        captureSession.commitConfiguration()
        
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        self.previewLayer = layer
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isProcessingFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        isProcessingFrame = true
        
        let request = VNDetectBarcodesRequest { [weak self] request, error in
            defer { self?.isProcessingFrame = false }
            guard let results = request.results as? [VNBarcodeObservation] else { return }
            
            for barcode in results where barcode.symbology == .qr {
                if let payload = barcode.payloadStringValue {
                    DispatchQueue.main.async {
                        self?.onCodeScanned?(payload)
                    }
                }
            }
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
    }
    
    deinit {
        captureSession.stopRunning()
    }
}

#endif
