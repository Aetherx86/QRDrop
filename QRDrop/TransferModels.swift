import Foundation
import CryptoKit

/// 오프라인 QR 파일 전송 프로토콜 패킷
/// 포맷: QRF1|fileID|chunkIndex|totalChunks|fileNameBase64|originalSize|sha256Prefix|payloadBase64
public struct TransferPacket: Sendable {
    public nonisolated static let magicHeader = "QRF1"
    
    public let fileID: String
    public let chunkIndex: Int
    public let totalChunks: Int
    public let fileName: String
    public let originalSize: Int
    public let sha256Prefix: String
    public let payloadData: Data
    
    public nonisolated init(
        fileID: String,
        chunkIndex: Int,
        totalChunks: Int,
        fileName: String,
        originalSize: Int,
        sha256Prefix: String,
        payloadData: Data
    ) {
        self.fileID = fileID
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.fileName = fileName
        self.originalSize = originalSize
        self.sha256Prefix = sha256Prefix
        self.payloadData = payloadData
    }
    
    /// 직렬화하여 QR 코드에 담길 문자열 생성
    public nonisolated func serialize() -> String {
        let fileNameBase64 = Data(fileName.utf8).base64EncodedString()
        let payloadBase64 = payloadData.base64EncodedString()
        return [
            Self.magicHeader,
            fileID,
            String(chunkIndex),
            String(totalChunks),
            fileNameBase64,
            String(originalSize),
            sha256Prefix,
            payloadBase64
        ].joined(separator: "|")
    }
    
    /// QR 코드 텍스트로부터 패킷 역직렬화
    public nonisolated static func deserialize(from text: String) -> TransferPacket? {
        let parts = text.components(separatedBy: "|")
        guard parts.count == 8, parts[0] == magicHeader else {
            return nil
        }
        
        let fileID = parts[1]
        guard let chunkIndex = Int(parts[2]),
              let totalChunks = Int(parts[3]),
              let fileNameData = Data(base64Encoded: parts[4]),
              let fileName = String(data: fileNameData, encoding: .utf8),
              let originalSize = Int(parts[5]),
              let payloadData = Data(base64Encoded: parts[7]) else {
            return nil
        }
        
        let sha256Prefix = parts[6]
        
        return TransferPacket(
            fileID: fileID,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            fileName: fileName,
            originalSize: originalSize,
            sha256Prefix: sha256Prefix,
            payloadData: payloadData
        )
    }
}

/// 데이터 압축 및 암호화 유틸리티
public enum DataCompressor {
    /// 데이터를 zlib 압축 (실패 시 원본 반환)
    public nonisolated static func compress(_ data: Data) -> Data {
        do {
            let compressed = try (data as NSData).compressed(using: .zlib) as Data
            return compressed.count < data.count ? compressed : data
        } catch {
            return data
        }
    }
    
    /// zlib 압축 해제
    public nonisolated static func decompress(_ data: Data) -> Data? {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            return data
        }
    }
    
    /// SHA-256 체크섬 계산 (앞 8자리 반환)
    public nonisolated static func sha256Prefix(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// 전송 파일 메타데이터
public struct TransferredFileInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let size: Int
    public let data: Data
    public let transferDuration: TimeInterval
    
    public nonisolated init(id: String, name: String, size: Int, data: Data, transferDuration: TimeInterval) {
        self.id = id
        self.name = name
        self.size = size
        self.data = data
        self.transferDuration = transferDuration
    }
    
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
