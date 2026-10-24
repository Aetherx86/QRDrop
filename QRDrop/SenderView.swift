import SwiftUI
import UniformTypeIdentifiers
#if canImport(PhotosUI)
import PhotosUI
#endif

public struct SenderView: View {
    @Bindable var viewModel: SenderViewModel
    
    @State private var isDropTargeted: Bool = false
    @State private var showFilePicker: Bool = false
    #if canImport(PhotosUI)
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif
    
    public init(viewModel: SenderViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // 상단 모드 선택 (텍스트 직접 입력 vs 파일/사진 드롭 전송)
            Picker("입력 방식", selection: $viewModel.inputMode) {
                ForEach(SenderViewModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            
            switch viewModel.inputMode {
            case .text:
                directTextInputView
            case .file:
                fileTransferModeView
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item, .image, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.processFile(at: url)
                }
            case .failure(let error):
                viewModel.errorMessage = "파일 선택 실패: \(error.localizedDescription)"
            }
        }
        #if canImport(PhotosUI)
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let item = newItem,
                   let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run {
                        self.viewModel.prepareFile(name: "사진_\(Int(Date().timeIntervalSince1970)).jpg", data: data)
                    }
                }
            }
        }
        #endif
    }
    
    // MARK: - 1. 텍스트 직접 입력 뷰 (실시간 QR 생성)
    
    private var directTextInputView: some View {
        ViewThatFits(in: .horizontal) {
            // 가로가 넓은 Mac / iPad 화면: 좌우 배치
            HStack(spacing: 20) {
                textInputArea
                    .frame(minWidth: 260)
                    .padding(.leading, 20)
                    .padding(.bottom, 16)
                
                qrCodePreviewArea(maxSize: 320)
                    .frame(width: 320)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            
            // 세로가 좁은 iPhone 화면: 상하 스크롤 배치
            ScrollView {
                VStack(spacing: 18) {
                    qrCodePreviewArea(maxSize: 260)
                        .frame(maxWidth: .infinity)
                    
                    textInputArea
                        .frame(minHeight: 180)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }
    
    private var textInputArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("보낼 텍스트 입력", systemImage: "pencil.line")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.directTextInput.count)자")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            
            TextEditor(text: $viewModel.directTextInput)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            
            // 퀵 액션 버튼
            HStack(spacing: 8) {
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("붙여넣기", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                
                Button {
                    viewModel.directTextInput = "https://"
                } label: {
                    Label("링크(URL)", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(role: .destructive) {
                    viewModel.clearDirectText()
                } label: {
                    Text("지우기")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }
    
    private func qrCodePreviewArea(maxSize: CGFloat) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
                
                if let qr = viewModel.currentQRImage {
                    Image(decorative: qr, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(18)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("텍스트를 입력하면\nQR 코드가 실시간 생성됩니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: maxSize, maxHeight: maxSize)
            
            HStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                #if os(macOS)
                Text("아이폰 카메라로 비추면 즉시 복사됩니다")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                #else
                Text("맥 카메라로 비추면 즉시 복사됩니다")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                #endif
            }
        }
    }

    // MARK: - 2. 파일 전송 모드 뷰
    
    private var fileTransferModeView: some View {
        VStack(spacing: 0) {
            if viewModel.selectedFileName == nil || viewModel.selectedFileName == "직접 입력 메모" {
                dropZoneView
            } else {
                if viewModel.isTextMode {
                    textPageQRView
                } else {
                    binaryAnimationQRView
                }
            }
        }
    }
    
    // MARK: - 3. 파일 텍스트 페이지 뷰
    
    private var textPageQRView: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedFileName ?? "파일")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text("\(viewModel.formattedOriginalSize) • 기본 카메라로 즉시 복사")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    viewModel.stopAutoPage()
                    viewModel.selectedFileName = nil
                    viewModel.currentQRImage = nil
                } label: {
                    Label("다른 파일", systemImage: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            
            Spacer(minLength: 4)
            
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
                
                if let qr = viewModel.currentQRImage {
                    Image(decorative: qr, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(24)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 380, maxHeight: 380)
            
            Spacer(minLength: 4)
            
            if viewModel.totalPages > 1 {
                HStack(spacing: 14) {
                    Button {
                        viewModel.previousPage()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        viewModel.toggleAutoPage()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: viewModel.isAutoPagePlaying ? "pause.fill" : "play.fill")
                            Text(viewModel.isAutoPagePlaying ? "자동 넘김 중" : "일시 정지")
                        }
                        .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Text("\(viewModel.currentPageIndex + 1) / \(viewModel.totalPages) 페이지")
                        .font(.system(.subheadline, design: .monospaced, weight: .bold))
                    
                    Button {
                        viewModel.nextPage()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
            }
            
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.blue)
                    #if os(macOS)
                    Text("아이폰 카메라를 켜서 비추세요!")
                        .font(.headline)
                    #else
                    Text("맥 카메라를 켜서 비추세요!")
                        .font(.headline)
                    #endif
                }
                Text("노란 박스 또는 우측 하단 [복사] 버튼을 누르면 내용이 바로 복사됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
    
    // MARK: - 4. 바이너리 파일/사진 고속 애니메이션 스트림 뷰
    
    private var binaryAnimationQRView: some View {
        VStack(spacing: 12) {
            // 상단 파일 정보 헤더
            HStack(spacing: 12) {
                Image(systemName: "photo.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedFileName ?? "파일")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text("\(viewModel.formattedOriginalSize) • 고속 전송 중 (\(viewModel.packets.count)개 프레임)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    viewModel.stopPlayback()
                    viewModel.selectedFileName = nil
                    viewModel.currentQRImage = nil
                } label: {
                    Label("다른 파일", systemImage: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            
            Spacer(minLength: 4)
            
            // 고속 QR 코드 디스플레이 영역
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
                
                if let qr = viewModel.currentQRImage {
                    Image(decorative: qr, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(22)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: 380, maxHeight: 380)
            
            Spacer(minLength: 4)
            
            // 재생 컨트롤 및 프레임 표시부
            HStack(spacing: 14) {
                Button {
                    viewModel.previousFrame()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                
                Button {
                    viewModel.togglePlayback()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        Text(viewModel.isPlaying ? "재생 중" : "정지")
                    }
                    .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                
                Text("\(viewModel.currentChunkIndex + 1) / \(max(1, viewModel.packets.count)) 프레임")
                    .font(.system(.subheadline, design: .monospaced, weight: .bold))
                
                Button {
                    viewModel.nextFrame()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            
            // 전송 속도 (FPS) 슬라이더 바
            HStack(spacing: 12) {
                Image(systemName: "hare.fill")
                    .foregroundStyle(.purple)
                
                Text("속도: \(Int(viewModel.fps)) FPS")
                    .font(.caption.monospacedDigit().bold())
                    .frame(width: 85, alignment: .leading)
                
                Slider(value: $viewModel.fps, in: 2.0...18.0, step: 1.0)
                
                Button("아이폰 17 초고속 (15 FPS)") {
                    viewModel.fps = 15.0
                }
                .font(.caption2.bold())
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
            
            // 가이드 문구 (중앙 정렬)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.viewfinder")
                        .foregroundStyle(.purple)
                    #if os(macOS)
                    Text("아이폰 QRDrop 앱의 [받기] 카메라로 비추세요!")
                        .font(.headline)
                    #else
                    Text("맥 QRDrop 앱의 [받기] 카메라로 비추세요!")
                        .font(.headline)
                    #endif
                }
                Text("QRDrop 전용 고속 광학 스트림으로 사진/바이너리 파일이 무선 복원됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }
    
    // MARK: - 5. Drop Zone View
    
    private var dropZoneView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 2, dash: [10, 8])
                    )
                
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 84, height: 84)
                        
                        Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "photo.on.rectangle.angled")
                            .font(.system(size: 42))
                            .foregroundStyle(Color.accentColor)
                            .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                            .animation(.spring(response: 0.3), value: isDropTargeted)
                    }
                    
                    VStack(spacing: 8) {
                        #if os(macOS)
                        Text("아이폰으로 전송할 사진 또는 파일을 드롭하세요")
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                        
                        Text("사진(JPG, PNG, HEIC), 문서, 코드(.swift, .py, .txt) 모두 지원\n고속 애니메이션 QR 스트림으로 수초 내에 전송됩니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #else
                        Text("맥(Mac)으로 전송할 사진 또는 파일을 선택하세요")
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                        
                        Text("사진 보관함에서 사진을 선택하거나 문서를 전송할 수 있습니다.\n상대 기기 QRDrop 카메라로 비추면 바로 복원됩니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    
                    HStack(spacing: 12) {
                        #if canImport(PhotosUI)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("사진 선택...", systemImage: "photo.badge.plus")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        #endif
                        
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("파일 찾아보기...", systemImage: "folder.badge.plus")
                                .font(.headline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        #if canImport(PhotosUI)
                        .buttonStyle(.bordered)
                        #else
                        .buttonStyle(.borderedProminent)
                        #endif
                        
                        Button {
                            viewModel.loadSampleFile()
                        } label: {
                            Label("샘플 파일", systemImage: "sparkles")
                                .font(.headline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(32)
            }
            .frame(maxWidth: 580, minHeight: 300)
            .padding(.horizontal, 24)
            .onDrop(of: [.fileURL, .item, .data, .plainText, .utf8PlainText, .image], isTargeted: $isDropTargeted) { providers in
                handleDroppedItems(providers)
            }
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            HStack(spacing: 14) {
                #if os(macOS)
                FeatureBadge(icon: "photo.fill", title: "사진 & 대용량", subtitle: "고속 QR 스트림")
                FeatureBadge(icon: "wifi.slash", title: "100% 완전 오프라인", subtitle: "인터넷/블루투스 불필요")
                FeatureBadge(icon: "hare.fill", title: "초고속 15+ FPS", subtitle: "아이폰 17 즉시 인식")
                #else
                FeatureBadge(icon: "photo.fill", title: "사진 앨범 연동", subtitle: "PhotosUI 완벽 지원")
                FeatureBadge(icon: "laptopcomputer", title: "맥으로 원스톱 전송", subtitle: "QR 스트림 스캔")
                FeatureBadge(icon: "shield.fill", title: "100% 에어갭 보안", subtitle: "망분리 환경 최적화")
                #endif
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            
            Spacer()
        }
    }
    
    // MARK: - Drag & Drop Handler
    
    private func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                }
                
                if let url = targetURL {
                    Task { @MainActor in
                        self.viewModel.processFile(at: url)
                    }
                }
            }
            return true
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.viewModel.processFile(at: url)
                    }
                } else if let data = item as? Data {
                    Task { @MainActor in
                        let name = provider.suggestedName ?? "드롭된_사진.jpg"
                        self.viewModel.prepareFile(name: name, data: data)
                    }
                }
            }
            return true
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text = text, let data = text.data(using: .utf8) else { return }
                Task { @MainActor in
                    self.viewModel.prepareFile(name: "드롭된_텍스트.txt", data: data)
                }
            }
            return true
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.viewModel.processFile(at: url)
                    }
                } else if let data = item as? Data {
                    Task { @MainActor in
                        let name = provider.suggestedName ?? "전송_파일.txt"
                        self.viewModel.prepareFile(name: name, data: data)
                    }
                }
            }
            return true
        }
        
        return false
    }
}

// MARK: - Feature Badge

struct FeatureBadge: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
            
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
