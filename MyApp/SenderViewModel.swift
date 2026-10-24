import Foundation
import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

@MainActor
@Observable
public final class SenderViewModel {
    // MARK: - Input Mode
    public enum InputMode: String, CaseIterable, Identifiable {
        case text = "✍️ 텍스트 직접 입력"
        case file = "📁 파일 드롭 전송"
        
        public var id: String { rawValue }
    }
    
    public var inputMode: InputMode = .text
    
    // MARK: - Direct Text Input State
    public var directTextInput: String = "" {
        didSet {
            if inputMode == .text {
                handleDirectTextChange()
            }
        }
    }
    
    // MARK: - File State
    public var selectedFileName: String?
    public var originalFileSize: Int = 0
    public var fileTextContent: String?
    
    // 텍스트 페이지 분할 (긴 글/코드)
    public var textPages: [String] = []
    public var currentPageIndex: Int = 0
    public var isTextMode: Bool = true
    
    // QR 생성 이미지
    public var currentQRImage: CGImage?
    public var isProcessingFile: Bool = false
    public var errorMessage: String?
    
    // 바이너리 파일 프레임 애니메이션
    public var packets: [TransferPacket] = []
    public var serializedStrings: [String] = []
    public var currentChunkIndex: Int = 0
    public var isPlaying: Bool = false
    public var fps: Double = 6.0
    public var loopCount: Int = 0
    
    private var playbackTask: Task<Void, Never>?
    
    public init() {
        directTextInput = "안녕하세요! 맥(Mac)에서 입력한 텍스트가 아이폰 카메라로 즉시 전송되었습니다. 🚀"
        handleDirectTextChange()
    }
    
    public var totalPages: Int {
        textPages.count
    }
    
    public var formattedOriginalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(originalFileSize), countStyle: .file)
    }
    
    // MARK: - Direct Text Handling
    
    public func handleDirectTextChange() {
        let trimmed = directTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            currentQRImage = nil
            textPages = []
            return
        }
        
        isTextMode = true
        selectedFileName = "직접 입력 메모"
        originalFileSize = trimmed.utf8.count
        
        let pageSize = 1500
        var pages: [String] = []
        var remaining = trimmed[...]
        while !remaining.isEmpty {
            let chunk = remaining.prefix(pageSize)
            pages.append(String(chunk))
            remaining = remaining.dropFirst(pageSize)
        }
        if pages.isEmpty { pages.append(trimmed) }
        
        self.textPages = pages
        self.currentPageIndex = min(self.currentPageIndex, max(0, pages.count - 1))
        updateTextPageQR()
    }
    
    public func pasteFromClipboard() {
        #if canImport(AppKit)
        if let clipboardString = NSPasteboard.general.string(forType: .string) {
            self.directTextInput = clipboardString
        }
        #endif
    }
    
    public func clearDirectText() {
        self.directTextInput = ""
        self.currentQRImage = nil
        self.textPages = []
    }
    
    // MARK: - File Processing
    
    public func processFile(at url: URL) {
        let isAccessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        isProcessingFile = true
        errorMessage = nil
        stopPlayback()
        
        do {
            let data = try Data(contentsOf: url)
            let fileName = url.lastPathComponent
            prepareFile(name: fileName, data: data)
        } catch {
            errorMessage = "파일 읽기 실패: \(error.localizedDescription)"
            isProcessingFile = false
        }
    }
    
    public func prepareFile(name: String, data: Data) {
        isProcessingFile = true
        errorMessage = nil
        stopPlayback()
        
        selectedFileName = name
        originalFileSize = data.count
        
        // 다중 인코딩 디코딩 시도
        var detectedText: String?
        let encodings: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            .utf16,
            .ascii,
            .isoLatin1
        ]
        
        for enc in encodings {
            if let str = String(data: data, encoding: enc) {
                let nonPrintable = str.unicodeScalars.filter { !CharacterSet.alphanumerics.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }.count
                if Double(nonPrintable) / Double(max(1, str.count)) < 0.25 {
                    detectedText = str
                    break
                }
            }
        }
        
        // 1. 텍스트 파일
        if let text = detectedText {
            isTextMode = true
            fileTextContent = text
            inputMode = .file
            
            let pageSize = 1500
            var pages: [String] = []
            var remaining = text[...]
            while !remaining.isEmpty {
                let chunk = remaining.prefix(pageSize)
                pages.append(String(chunk))
                remaining = remaining.dropFirst(pageSize)
            }
            if pages.isEmpty { pages.append(text) }
            
            self.textPages = pages
            self.currentPageIndex = 0
            self.updateTextPageQR()
            self.isProcessingFile = false
            return
        }
        
        // 2. 바이너리 파일
        isTextMode = false
        fileTextContent = nil
        textPages = []
        inputMode = .file
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let originalSize = data.count
            let compressedData = DataCompressor.compress(data)
            let sha256 = DataCompressor.sha256Prefix(for: compressedData)
            let fileID = UUID().uuidString.prefix(6).lowercased()
            
            var generatedPackets: [TransferPacket] = []
            var generatedStrings: [String] = []
            
            let chunkSize = 300
            let totalChunks = max(1, Int(ceil(Double(compressedData.count) / Double(chunkSize))))
            
            for index in 0..<totalChunks {
                let startOffset = index * chunkSize
                let endOffset = min(startOffset + chunkSize, compressedData.count)
                let chunkData = compressedData.subdata(in: startOffset..<endOffset)
                
                let packet = TransferPacket(
                    fileID: fileID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    fileName: name,
                    originalSize: originalSize,
                    sha256Prefix: sha256,
                    payloadData: chunkData
                )
                generatedPackets.append(packet)
                generatedStrings.append(packet.serialize())
            }
            
            await self.applyGeneratedPackets(generatedPackets, strings: generatedStrings)
        }
    }
    
    private func applyGeneratedPackets(_ packets: [TransferPacket], strings: [String]) {
        self.packets = packets
        self.serializedStrings = strings
        self.currentChunkIndex = 0
        self.loopCount = 0
        self.isProcessingFile = false
        
        self.updateCurrentQRImage()
        self.startPlayback()
    }
    
    // MARK: - 텍스트 페이지 이동
    
    public func nextPage() {
        guard currentPageIndex < textPages.count - 1 else { return }
        currentPageIndex += 1
        updateTextPageQR()
    }
    
    public func previousPage() {
        guard currentPageIndex > 0 else { return }
        currentPageIndex -= 1
        updateTextPageQR()
    }
    
    private func updateTextPageQR() {
        guard currentPageIndex >= 0, currentPageIndex < textPages.count else { return }
        let pageText = textPages[currentPageIndex]
        currentQRImage = QRGenerator.shared.generateQRCode(from: pageText, targetSize: 650)
    }
    
    // MARK: - Playback Control (바이너리용)
    
    public func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }
    
    public func startPlayback() {
        guard !packets.isEmpty else { return }
        stopPlayback()
        isPlaying = true
        
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let currentInterval = 1.0 / max(1.0, self.fps)
                
                try? await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
                
                if Task.isCancelled { break }
                
                await MainActor.run {
                    self.nextFrame()
                }
            }
        }
    }
    
    public func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }
    
    public func nextFrame() {
        guard !packets.isEmpty else { return }
        let nextIndex = currentChunkIndex + 1
        if nextIndex >= packets.count {
            currentChunkIndex = 0
            loopCount += 1
        } else {
            currentChunkIndex = nextIndex
        }
        updateCurrentQRImage()
    }
    
    public func previousFrame() {
        guard !packets.isEmpty else { return }
        if currentChunkIndex > 0 {
            currentChunkIndex -= 1
        } else {
            currentChunkIndex = packets.count - 1
        }
        updateCurrentQRImage()
    }
    
    private func updateCurrentQRImage() {
        guard currentChunkIndex >= 0, currentChunkIndex < serializedStrings.count else {
            currentQRImage = nil
            return
        }
        let text = serializedStrings[currentChunkIndex]
        currentQRImage = QRGenerator.shared.generateQRCode(from: text, targetSize: 650)
    }
    
    public func loadSampleFile() {
        let sampleText = """
        [QRDrop 전송 성공]
        맥에서 아이폰으로 전송된 텍스트입니다!
        수신 엔진이나 별도 앱 설치 없이,
        아이폰 기본 카메라만으로 100% 수신되었습니다.
        
        • 전송 시간: \(Date().formatted())
        • 파일 형식: 순수 텍스트 오프라인 전송
        
        노란색 텍스트 박스 또는 우측 하단 [복사] 버튼을 누르면 바로 메모장 등에 붙여넣기 하실 수 있습니다!
        """
        guard let data = sampleText.data(using: .utf8) else { return }
        prepareFile(name: "테스트_메모.txt", data: data)
    }
}
