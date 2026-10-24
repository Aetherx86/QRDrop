import Foundation
import SwiftUI
import CryptoKit
#if canImport(AudioToolbox)
import AudioToolbox
#endif

@MainActor
@Observable
public final class ReceiverViewModel {
    // MARK: - Current Transfer State
    public var activeFileID: String?
    public var fileName: String = ""
    public var originalSize: Int = 0
    public var sha256Prefix: String = ""
    public var totalChunks: Int = 0
    
    // 수신된 청크 딕셔너리 [chunkIndex: Data]
    public var receivedChunks: [Int: Data] = [:]
    public var receivedIndices: Set<Int> = []
    
    // 진행률 및 상태
    public var isReceiving: Bool = false
    public var transferStartTime: Date?
    public var lastPacketReceiveTime: Date?
    public var scanRateFPS: Double = 0.0
    
    // 완료된 파일
    public var completedFile: TransferredFileInfo?
    public var showCompletionSheet: Bool = false
    public var statusMessage: String = "카메라를 맥 화면의 QR 코드에 비춰주세요"
    public var errorMessage: String?
    
    // FPS 계산용 카운터
    private var scanTimestamps: [Date] = []
    
    public init() {}
    
    public var progress: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(receivedChunks.count) / Double(totalChunks)
    }
    
    public var receivedCount: Int {
        receivedChunks.count
    }
    
    public var missingIndices: [Int] {
        guard totalChunks > 0 else { return [] }
        return (0..<totalChunks).filter { !receivedIndices.contains($0) }
    }
    
    public var missingChunksSummary: String {
        let missing = missingIndices
        if missing.isEmpty {
            return "모든 청크 수신 완료"
        }
        if missing.count <= 6 {
            return "남은 청크: #" + missing.map(String.init).joined(separator: ", #")
        } else {
            return "남은 청크: \(missing.count)개"
        }
    }
    
    public var formattedOriginalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(originalSize), countStyle: .file)
    }
    
    // MARK: - Processing Scanned Codes
    
    public func processScannedCode(_ text: String) {
        guard let packet = TransferPacket.deserialize(from: text) else {
            return
        }
        
        recordScanEvent()
        
        // 새 전송 세션 시작 감지
        if activeFileID != packet.fileID {
            // 새 파일 전송 시작
            startNewSession(with: packet)
        }
        
        // 이미 받은 청크인지 확인
        if receivedIndices.contains(packet.chunkIndex) {
            return
        }
        
        // 청크 저장
        receivedChunks[packet.chunkIndex] = packet.payloadData
        receivedIndices.insert(packet.chunkIndex)
        lastPacketReceiveTime = Date()
        
        triggerLightHaptic()
        statusMessage = "수신 중: \(receivedChunks.count) / \(totalChunks) 프레임 (\(Int(progress * 100))%)"
        
        // 완료 여부 검사
        if receivedChunks.count == totalChunks {
            assembleAndFinalize()
        }
    }
    
    private func startNewSession(with packet: TransferPacket) {
        activeFileID = packet.fileID
        fileName = packet.fileName
        originalSize = packet.originalSize
        sha256Prefix = packet.sha256Prefix
        totalChunks = packet.totalChunks
        receivedChunks = [:]
        receivedIndices = []
        isReceiving = true
        transferStartTime = Date()
        completedFile = nil
        errorMessage = nil
        statusMessage = "새로운 파일 전송 감지: \(packet.fileName)"
        
        triggerMediumHaptic()
    }
    
    private func assembleAndFinalize() {
        guard let startTime = transferStartTime else { return }
        let duration = max(0.1, Date().timeIntervalSince(startTime))
        
        statusMessage = "데이터 조립 및 무결성 검증 중..."
        
        // 0부터 totalChunks-1까지 정렬하여 압축 데이터 병합
        var fullCompressedData = Data()
        for i in 0..<totalChunks {
            guard let chunk = receivedChunks[i] else {
                errorMessage = "누락된 청크가 있습니다 (#\(i))"
                return
            }
            fullCompressedData.append(chunk)
        }
        
        // 체크섬 검증
        let calculatedHash = DataCompressor.sha256Prefix(for: fullCompressedData)
        if !sha256Prefix.isEmpty && calculatedHash != sha256Prefix {
            errorMessage = "데이터 체크섬 불일치 (전송 오류)"
            statusMessage = "체크섬 검증 실패"
            return
        }
        
        // 압축 해제
        guard let finalData = DataCompressor.decompress(fullCompressedData) else {
            errorMessage = "파일 압축 해제 실패"
            statusMessage = "압축 해제 실패"
            return
        }
        
        let fileInfo = TransferredFileInfo(
            id: activeFileID ?? UUID().uuidString,
            name: fileName,
            size: finalData.count,
            data: finalData,
            transferDuration: duration
        )
        
        completedFile = fileInfo
        showCompletionSheet = true
        isReceiving = false
        statusMessage = "전송 완료! (\(fileInfo.formattedSize), \(String(format: "%.1f", duration))초)"
        
        triggerSuccessFeedback()
    }
    
    public func reset() {
        activeFileID = nil
        fileName = ""
        originalSize = 0
        sha256Prefix = ""
        totalChunks = 0
        receivedChunks.removeAll()
        receivedIndices.removeAll()
        isReceiving = false
        transferStartTime = nil
        completedFile = nil
        errorMessage = nil
        statusMessage = "카메라를 맥 화면의 QR 코드에 비춰주세요"
    }
    
    private func recordScanEvent() {
        let now = Date()
        scanTimestamps.append(now)
        // 최근 1초 내 타임스탬프만 유지
        scanTimestamps = scanTimestamps.filter { now.timeIntervalSince($0) <= 1.0 }
        scanRateFPS = Double(scanTimestamps.count)
    }
    
    private func triggerLightHaptic() {
        #if os(iOS)
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        #endif
    }
    
    private func triggerMediumHaptic() {
        #if os(iOS)
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        #endif
    }
    
    private func triggerSuccessFeedback() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #elseif os(macOS)
        NSSound.beep()
        #endif
    }
}
