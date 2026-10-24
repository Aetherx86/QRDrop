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
            // 상단 서브 세그먼트 (텍스트 직접 입력 vs 모든 파일/사진 전송)
            Picker("입력 방식", selection: $viewModel.inputMode) {
                ForEach(SenderViewModel.InputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            
            switch viewModel.inputMode {
            case .text:
                directTextInputView
            case .file:
                fileTransferModeView
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item, .content, .data, .image, .pdf],
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
            HStack(spacing: 16) {
                textInputArea
                    .frame(minWidth: 260)
                    .padding(.leading, 16)
                    .padding(.bottom, 12)
                
                qrCodePreviewArea(maxSize: 320)
                    .frame(width: 320)
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
            }
            
            // 세로가 좁은 iPhone 화면: 상하 스크롤 배치
            ScrollView {
                VStack(spacing: 14) {
                    qrCodePreviewArea(maxSize: 260)
                        .frame(maxWidth: .infinity)
                    
                    textInputArea
                        .frame(minHeight: 180)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }
    
    private var textInputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("보낼 텍스트 입력", systemImage: "pencil.line")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(viewModel.directTextInput.count)자")
                    .font(.caption2.monospacedDigit())
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
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                
                Button {
                    viewModel.directTextInput = "https://"
                } label: {
                    Label("URL", systemImage: "link")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(role: .destructive) {
                    viewModel.clearDirectText()
                } label: {
                    Text("지우기")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }
    
    private func qrCodePreviewArea(maxSize: CGFloat) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
                
                if let qr = viewModel.currentQRImage {
                    Image(decorative: qr, scale: 1.0)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(16)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 32))
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
                    .font(.caption2)
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
        VStack(spacing: 10) {
            // 상단 파일 정보 바
            HStack(spacing: 10) {
                Image(systemName: "doc.text.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedFileName ?? "파일")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text("\(viewModel.formattedOriginalSize) • 텍스트 모드")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    viewModel.stopAutoPage()
                    viewModel.selectedFileName = nil
                    viewModel.currentQRImage = nil
                } label: {
                    Label("다른 파일", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            
            Spacer(minLength: 4)
            
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
                    ProgressView()
                }
            }
            .frame(maxWidth: 340, maxHeight: 340)
            
            Spacer(minLength: 4)
            
            if viewModel.totalPages > 1 {
                HStack(spacing: 12) {
                    Button {
                        viewModel.previousPage()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        viewModel.toggleAutoPage()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.isAutoPagePlaying ? "pause.fill" : "play.fill")
                            Text(viewModel.isAutoPagePlaying ? "자동 넘김 중" : "일시 정지")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Text("\(viewModel.currentPageIndex + 1) / \(viewModel.totalPages) 페이지")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                    
                    Button {
                        viewModel.nextPage()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 12)
            }
            
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    #if os(macOS)
                    Text("아이폰 카메라를 켜서 비추세요!")
                        .font(.subheadline.bold())
                    #else
                    Text("맥 카메라를 켜서 비추세요!")
                        .font(.subheadline.bold())
                    #endif
                }
                Text("노란 박스 또는 우측 하단 [복사] 버튼을 누르면 내용이 바로 복사됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
    
    // MARK: - 4. 모든 파일(사진, PDF, PPT 등) 고속 애니메이션 스트림 뷰
    
    private var binaryAnimationQRView: some View {
        VStack(spacing: 10) {
            // 상단 파일 정보 헤더 바
            HStack(spacing: 10) {
                Image(systemName: fileIconName(for: viewModel.selectedFileName ?? ""))
                    .font(.title3)
                    .foregroundStyle(.purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedFileName ?? "파일")
                        .font(.subheadline.bold())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Text("\(viewModel.formattedOriginalSize) • 총 \(viewModel.packets.count)개 프레임")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    viewModel.stopPlayback()
                    viewModel.selectedFileName = nil
                    viewModel.currentQRImage = nil
                } label: {
                    Label("다른 파일", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            
            Spacer(minLength: 2)
            
            // 고속 QR 코드 디스플레이 영역
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
                    ProgressView()
                }
            }
            .frame(maxWidth: 340, maxHeight: 340)
            
            Spacer(minLength: 2)
            
            // 프레임 이동 및 재생 토글 바
            HStack(spacing: 12) {
                Button {
                    viewModel.previousFrame()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                
                Button {
                    viewModel.togglePlayback()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        Text(viewModel.isPlaying ? "자동 전송 중" : "일시 정지")
                    }
                    .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                
                Text("\(viewModel.currentChunkIndex + 1) / \(max(1, viewModel.packets.count))")
                    .font(.system(.caption, design: .monospaced, weight: .bold))
                
                Button {
                    viewModel.nextFrame()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            
            // 🐢 거북이 ~ 🐇 토끼 FPS 속도 조절 슬라이더
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    
                    Slider(value: $viewModel.fps, in: 2.0...60.0, step: 1.0)
                        .tint(.purple)
                    
                    Image(systemName: "hare.fill")
                        .font(.subheadline)
                        .foregroundStyle(.purple)
                    
                    Text("\(Int(viewModel.fps)) FPS")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 50, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                
                // 속도 프리셋 뱃지 버튼들 (1줄에 딱 맞춤)
                HStack(spacing: 6) {
                    speedPresetButton(fps: 12, title: "표준 (12)")
                    speedPresetButton(fps: 24, title: "고속 (24)")
                    speedPresetButton(fps: 36, title: "아이폰17 (36)")
                    speedPresetButton(fps: 60, title: "초고속 60 FPS")
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 4)
            
            // 안내 문구
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "camera.viewfinder")
                        .foregroundStyle(.purple)
                        .font(.caption)
                    #if os(macOS)
                    Text("아이폰 QRDrop 앱의 [받기] 카메라로 비추세요!")
                        .font(.subheadline.bold())
                    #else
                    Text("맥 QRDrop 앱의 [받기] 카메라로 비추세요!")
                        .font(.subheadline.bold())
                    #endif
                }
                Text("실시간 QR 스트림으로 사진, PDF, PPT 등 모든 파일이 무선 복원됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
    
    @ViewBuilder
    private func speedPresetButton(fps: Double, title: String) -> some View {
        let isSelected = Int(viewModel.fps) == Int(fps)
        if isSelected {
            Button {
                viewModel.fps = fps
            } label: {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                viewModel.fps = fps
            } label: {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
        }
    }
    
    // MARK: - 5. Drop Zone View (모든 파일 지원)
    
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 3 : 2, dash: [8, 6])
                    )
                
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 72, height: 72)
                        
                        Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.accentColor)
                            .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                            .animation(.spring(response: 0.3), value: isDropTargeted)
                    }
                    
                    VStack(spacing: 6) {
                        #if os(macOS)
                        Text("전송할 파일이나 사진을 드롭하세요")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        Text("사진, PDF, PPT, Word, Excel, 코드, 압축파일 등 모든 형식 지원\n초고속 광학 애니메이션 스트림으로 즉시 전송됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #else
                        Text("맥으로 보낼 파일이나 사진을 선택하세요")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        
                        Text("사진 보관함, PDF, PPT, 문서 등 모든 파일을 선택할 수 있습니다.\n맥 카메라로 비추면 바로 복원되어 저장됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    
                    // 파일 및 사진 선택 버튼들
                    HStack(spacing: 10) {
                        #if canImport(PhotosUI)
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label("사진 앨범", systemImage: "photo.badge.plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        #endif
                        
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("모든 파일...", systemImage: "folder.badge.plus")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
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
                            Label("샘플", systemImage: "sparkles")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: 560, minHeight: 250)
            .padding(.horizontal, 14)
            .onDrop(of: [.fileURL, .item, .content, .data, .plainText, .utf8PlainText, .image, .pdf], isTargeted: $isDropTargeted) { providers in
                handleDroppedItems(providers)
            }
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // 하단 특징 배지 3개
            HStack(spacing: 8) {
                FeatureBadge(icon: "doc.fill", title: "모든 파일 지원", subtitle: "사진·PDF·PPT·ZIP")
                FeatureBadge(icon: "wifi.slash", title: "100% 완전 오프라인", subtitle: "인터넷·블루투스 불필요")
                FeatureBadge(icon: "hare.fill", title: "초당 최대 60 FPS", subtitle: "아이폰 17 초고속 스트림")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            
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
        
        if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.content.identifier) ||
            provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.viewModel.processFile(at: url)
                    }
                } else if let data = item as? Data {
                    Task { @MainActor in
                        let name = provider.suggestedName ?? "전송_파일"
                        self.viewModel.prepareFile(name: name, data: data)
                    }
                }
            }
            return true
        }
        
        return false
    }
    
    private func fileIconName(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".pdf") {
            return "doc.richtext.fill"
        } else if lower.hasSuffix(".ppt") || lower.hasSuffix(".pptx") || lower.hasSuffix(".key") {
            return "presentation.fill"
        } else if lower.hasSuffix(".doc") || lower.hasSuffix(".docx") || lower.hasSuffix(".pages") {
            return "doc.text.fill"
        } else if lower.hasSuffix(".xls") || lower.hasSuffix(".xlsx") || lower.hasSuffix(".numbers") || lower.hasSuffix(".csv") {
            return "tablecells.fill"
        } else if lower.hasSuffix(".zip") || lower.hasSuffix(".tar") || lower.hasSuffix(".gz") {
            return "archivebox.fill"
        } else if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".heic") {
            return "photo.fill"
        } else {
            return "doc.fill"
        }
    }
}

// MARK: - Feature Badge

struct FeatureBadge: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.blue)
            
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
            
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
