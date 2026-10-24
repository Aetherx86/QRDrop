import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct ReceiverView: View {
    @Bindable var viewModel: ReceiverViewModel
    
    public init(viewModel: ReceiverViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack {
            // 카메라 뷰파인더
            CameraScannerView { code in
                viewModel.processScannedCode(code)
            }
            .ignoresSafeArea()
            
            // 상/하단 오버레이 HUD
            VStack {
                // 상단 HUD: 수신 상태
                topHUDView
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                
                Spacer()
                
                // 하단 HUD: 청크 수신 진행 상태 및 비트맵 맵
                bottomStatusCard
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $viewModel.showCompletionSheet) {
            if let file = viewModel.completedFile {
                CompletedFileSheet(file: file) {
                    viewModel.reset()
                }
            }
        }
    }
    
    // MARK: - Top HUD
    
    private var topHUDView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // 실시간 스캔 속도 표시
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.scanRateFPS > 0 ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("\(Int(viewModel.scanRateFPS)) FPS")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                
                Spacer()
                
                if viewModel.isReceiving {
                    Button("초기화") {
                        viewModel.reset()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.7), in: Capsule())
                }
            }
            
            // 파일 정보 & 프로그레스
            if viewModel.isReceiving {
                VStack(spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.fileName)
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            Text("\(viewModel.formattedOriginalSize) • 총 \(viewModel.totalChunks)개 프레임")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        Text("\(Int(viewModel.progress * 100))%")
                            .font(.system(.title3, design: .rounded, weight: .black))
                            .foregroundStyle(.cyan)
                    }
                    
                    ProgressView(value: viewModel.progress)
                        .tint(.cyan)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    
    // MARK: - Bottom Status Card
    
    private var bottomStatusCard: some View {
        VStack(spacing: 12) {
            Text(viewModel.statusMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            
            if viewModel.totalChunks > 0 {
                // 실시간 청크 수신 매트릭스 그리드
                ChunkMatrixView(
                    totalChunks: viewModel.totalChunks,
                    receivedIndices: viewModel.receivedIndices
                )
                .frame(maxHeight: 100)
                
                Text(viewModel.missingChunksSummary)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Chunk Matrix View (청크 수신 비트맵 시각화)

struct ChunkMatrixView: View {
    let totalChunks: Int
    let receivedIndices: Set<Int>
    
    var body: some View {
        let displayCount = min(totalChunks, 150)
        let columns = [GridItem(.adaptive(minimum: 12, maximum: 16), spacing: 4)]
        
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(0..<displayCount, id: \.self) { index in
                    let isReceived = receivedIndices.contains(index)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isReceived ? Color.cyan : Color.white.opacity(0.18))
                        .frame(height: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(isReceived ? Color.white.opacity(0.6) : Color.clear, lineWidth: 0.5)
                        )
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Completed File Sheet

struct CompletedFileSheet: View {
    let file: TransferredFileInfo
    let onDismiss: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var saveSuccessMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 성공 헤더
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.green)
                    }
                    
                    Text("파일 수신 완료!")
                        .font(.title2.bold())
                    
                    Text("오프라인 QR 애니메이션을 통해 성공적으로 복원되었습니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 16)
                
                // 파일 정보 카드
                VStack(spacing: 12) {
                    HStack {
                        Text("파일명")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(file.name)
                            .bold()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .minimumScaleFactor(0.75)
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("파일 크기")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(file.formattedSize)
                            .bold()
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("소요 시간")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f초", file.transferDuration))
                            .bold()
                    }
                    
                    Divider()
                    
                    HStack {
                        Text("평균 전송 속도")
                            .foregroundStyle(.secondary)
                        Spacer()
                        let speedKBps = (Double(file.size) / 1024.0) / max(0.1, file.transferDuration)
                        Text(String(format: "%.1f KB/s", speedKBps))
                            .bold()
                            .foregroundStyle(.blue)
                    }
                }
                .font(.subheadline)
                .padding(16)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20)
                
                // 미리보기 영역 (텍스트 또는 이미지인 경우)
                previewSection
                    .padding(.horizontal, 20)
                
                Spacer()
                
                if let msg = saveSuccessMessage {
                    Text(msg)
                        .font(.footnote.bold())
                        .foregroundStyle(.green)
                }
                
                // 동작 버튼
                HStack(spacing: 14) {
                    Button {
                        saveFileToDisk()
                    } label: {
                        Label("파일로 저장", systemImage: "square.and.arrow.down.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    
                    ShareLink(
                        item: fileShareData(),
                        preview: SharePreview(file.name, image: Image(systemName: "doc.fill"))
                    ) {
                        Label("공유", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("수신 완료")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                        onDismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var previewSection: some View {
        if let stringContent = String(data: file.data, encoding: .utf8), !stringContent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("미리보기")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(stringContent)
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        } else {
            imagePreviewSection
        }
    }
    
    @ViewBuilder
    private var imagePreviewSection: some View {
        #if canImport(AppKit)
        if let nsImage = NSImage(data: file.data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        #elseif canImport(UIKit)
        if let uiImage = UIImage(data: file.data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        #endif
    }
    
    private func fileShareData() -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        try? file.data.write(to: tempURL)
        return tempURL
    }
    
    private func saveFileToDisk() {
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = file.name
        savePanel.canCreateDirectories = true
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                do {
                    try file.data.write(to: targetURL)
                    saveSuccessMessage = "파일이 성공적으로 저장되었습니다!"
                } catch {
                    saveSuccessMessage = "저장 실패: \(error.localizedDescription)"
                }
            }
        }
        #elseif os(iOS)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        do {
            try file.data.write(to: tempURL)
            saveSuccessMessage = "공유 버튼을 통해 파일 앱이나 사진첩에 저장할 수 있습니다."
        } catch {
            saveSuccessMessage = "저장 실패: \(error.localizedDescription)"
        }
        #endif
    }
}
