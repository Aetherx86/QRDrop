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
    public var activeFlags: PacketFlags = [.zlibCompressed]
    public var activeProtocolVersion: Int = 1
    public var decryptionPassphrase: String = ""

    // 수신된 청크 딕셔너리 [chunkIndex: Data]
    public var receivedChunks: [Int: Data] = [:]
    public var receivedIndices: Set<Int> = []
    public var fountainDecoder: FountainDecoder?

    // 진행률 및 상태
    public var isReceiving: Bool = false
    public var transferStartTime: Date?
    public var lastPacketReceiveTime: Date?
    public var scanRateFPS: Double = 0.0

    // 완료된 파일
    public var completedFile: TransferredFileInfo?
    public var showCompletionSheet: Bool = false
    #if os(macOS)
    public var statusMessage: String = "카메라를 아이폰 화면의 QR 코드에 비춰주세요"
    #else
    public var statusMessage: String = "카메라를 맥 화면의 QR 코드에 비춰주세요"
    #endif
    public var errorMessage: String?

    // FPS 계산용 카운터
    private var scanTimestamps: [Date] = []

    public init() {}

    public var progress: Double {
        guard totalChunks > 0 else { return 0 }
        return Double(receivedCount) / Double(totalChunks)
    }

    public var receivedCount: Int {
        if let decoder = fountainDecoder {
            return decoder.rank
        }
        return receivedChunks.count
    }

    public var missingIndices: [Int] {
        guard totalChunks > 0 else { return [] }
        if let decoder = fountainDecoder {
            let remaining = max(0, totalChunks - decoder.rank)
            return Array(0..<remaining)
        }
        return (0..<totalChunks).filter { !receivedIndices.contains($0) }
    }

    public var missingChunksSummary: String {
        if let decoder = fountainDecoder {
            let remaining = max(0, decoder.sourceBlocks - decoder.rank)
            if remaining == 0 {
                return "모든 파운틴 블록 복원 완료"
            }
            return "추가 필요 파운틴 드롭릿: \(remaining)개"
        }
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
        if text.hasPrefix(FountainDroplet.magicHeader + "|") {
            guard let droplet = FountainDroplet.deserialize(from: text) else {
                return
            }
            processFountainDroplet(droplet)
            return
        }

        guard let packet = TransferPacket.deserialize(from: text) else {
            return
        }

        recordScanEvent()

        // 새 전송 세션 시작 감지
        if activeFileID != packet.fileID || fountainDecoder != nil {
            startNewSession(with: packet)
        } else if packet.totalChunks != totalChunks || packet.originalSize != originalSize {
            return
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

    private func processFountainDroplet(_ droplet: FountainDroplet) {
        recordScanEvent()

        if activeFileID != droplet.fileID || fountainDecoder == nil {
            activeFileID = droplet.fileID
            fileName = droplet.fileName
            originalSize = droplet.originalSize
            sha256Prefix = droplet.sha256Hex
            totalChunks = droplet.sourceBlocks
            activeFlags = droplet.flags
            activeProtocolVersion = 2
            receivedChunks = [:]
            receivedIndices = []
            fountainDecoder = FountainDecoder(
                fileID: droplet.fileID,
                sourceBlocks: droplet.sourceBlocks,
                blockSize: droplet.blockSize,
                streamLength: droplet.streamLength,
                originalSize: droplet.originalSize,
                sha256Hex: droplet.sha256Hex
            )
            isReceiving = true
            transferStartTime = Date()
            completedFile = nil
            errorMessage = nil
            statusMessage = "새로운 파운틴 파일 전송 감지: \(droplet.fileName)"
            triggerMediumHaptic()
        }

        guard var decoder = fountainDecoder else { return }
        let prevRank = decoder.rank
        guard decoder.ingest(droplet) else { return }
        fountainDecoder = decoder

        if decoder.rank > prevRank {
            receivedIndices = Set(0..<decoder.rank)
            lastPacketReceiveTime = Date()
            triggerLightHaptic()
            statusMessage = "파운틴 수신 중: \(decoder.rank) / \(totalChunks) 블록 (\(Int(progress * 100))%)"
        }

        if let streamData = decoder.reconstructedStream() {
            finalizeReconstructedStream(streamData)
        }
    }

    private func startNewSession(with packet: TransferPacket) {
        activeFileID = packet.fileID
        fileName = packet.fileName
        originalSize = packet.originalSize
        sha256Prefix = packet.sha256Prefix
        totalChunks = packet.totalChunks
        activeFlags = packet.flags
        activeProtocolVersion = packet.protocolVersion
        fountainDecoder = nil
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
        statusMessage = "데이터 조립 및 무결성 검증 중..."

        // 0부터 totalChunks-1까지 정렬하여 압축 데이터 병합
        var fullStreamData = Data()
        for i in 0..<totalChunks {
            guard let chunk = receivedChunks[i] else {
                errorMessage = "누락된 청크가 있습니다 (#\(i))"
                return
            }
            fullStreamData.append(chunk)
        }

        finalizeReconstructedStream(fullStreamData)
    }

    private func finalizeReconstructedStream(_ fullStreamData: Data) {
        guard let startTime = transferStartTime else { return }
        let duration = max(0.1, Date().timeIntervalSince(startTime))

        // 체크섬 검증 (8자리 prefix 또는 64자리 SHA-256 모두 지원)
        if !sha256Prefix.isEmpty && !DataCompressor.verifySHA256(fullStreamData, expectedHexOrPrefix: sha256Prefix) {
            errorMessage = "데이터 체크섬 불일치 (전송 오류)"
            statusMessage = "체크섬 검증 실패"
            return
        }

        // 암호화된 스트림인 경우 복호화
        let decryptedStream: Data
        if activeFlags.contains(.encryptedAESGCM) {
            guard !decryptionPassphrase.isEmpty else {
                errorMessage = "암호화된 전송입니다. 복호화 패스프레이즈가 필요합니다."
                statusMessage = "복호화 패스프레이즈 필요"
                return
            }
            do {
                decryptedStream = try EncryptedPayloadEnvelope.unpackBinary(
                    packed: fullStreamData,
                    passphrase: decryptionPassphrase,
                    context: activeFileID ?? ""
                )
            } catch {
                errorMessage = "AES-GCM 복호화 및 인증 실패"
                statusMessage = "복호화 실패"
                return
            }
        } else {
            decryptedStream = fullStreamData
        }

        // 압축 해제
        let isCompressed = activeProtocolVersion == 1 ? true : activeFlags.contains(.zlibCompressed)
        guard let finalData = DataCompressor.decompressBounded(
            decryptedStream,
            isCompressed: isCompressed,
            expectedSize: originalSize
        ) else {
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
        activeFlags = [.zlibCompressed]
        activeProtocolVersion = 1
        fountainDecoder = nil
        receivedChunks.removeAll()
        receivedIndices.removeAll()
        isReceiving = false
        transferStartTime = nil
        completedFile = nil
        errorMessage = nil
        #if os(macOS)
        statusMessage = "카메라를 아이폰 화면의 QR 코드에 비춰주세요"
        #else
        statusMessage = "카메라를 맥 화면의 QR 코드에 비춰주세요"
        #endif
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
