import Foundation
import CryptoKit

/// Version metadata for QRDrop library, app, and CLI.
public nonisolated enum QRDropVersion {
    public static let current = "0.2.0"
}

/// IEEE 802.3 CRC-32 checksum calculator for per-frame QR packet integrity verification.
public nonisolated enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFFFFFF
    }

    public static func hex(_ data: Data) -> String {
        String(format: "%08x", checksum(data))
    }

    public static func verify(_ data: Data, expectedHex: String) -> Bool {
        let normalized = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 8, normalized.allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        return hex(data) == normalized
    }
}

/// Bitflags describing transformations applied to a transfer stream.
public nonisolated struct PacketFlags: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let none: PacketFlags = []
    public static let zlibCompressed = PacketFlags(rawValue: 1 << 0)
    public static let encryptedAESGCM = PacketFlags(rawValue: 1 << 1)
    public static let fountainCoded = PacketFlags(rawValue: 1 << 2)
}

/// 오프라인 QR 파일 전송 프로토콜 패킷
/// QRF1 포맷: QRF1|fileID|chunkIndex|totalChunks|fileNameBase64|originalSize|sha256Prefix|payloadBase64
/// QRF2 포맷: QRF2|fileID|chunkIndex|totalChunks|flags|fileNameBase64|originalSize|sha256Hex|chunkCRC32Hex|payloadBase64
public nonisolated struct TransferPacket: Sendable, Equatable {
    public static let magicHeader = "QRF1"
    public static let magicHeaderV2 = "QRF2"

    public static let defaultMaxTotalChunks = 65_536
    public static let defaultMaxOriginalSize = 100 * 1024 * 1024
    public static let defaultMaxChunkBytes = 16_384

    public let protocolVersion: Int
    public let fileID: String
    public let chunkIndex: Int
    public let totalChunks: Int
    public let flags: PacketFlags
    public let fileName: String
    public let originalSize: Int
    public let sha256Prefix: String
    public let chunkCRC32: String
    public let payloadData: Data

    public init(
        fileID: String,
        chunkIndex: Int,
        totalChunks: Int,
        fileName: String,
        originalSize: Int,
        sha256Prefix: String,
        payloadData: Data,
        protocolVersion: Int = 1,
        flags: PacketFlags = [.zlibCompressed],
        chunkCRC32: String? = nil
    ) {
        self.protocolVersion = protocolVersion == 2 ? 2 : 1
        self.fileID = fileID
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.flags = flags
        self.fileName = Self.sanitizeFileName(fileName)
        self.originalSize = originalSize
        self.sha256Prefix = sha256Prefix.lowercased()
        self.chunkCRC32 = (chunkCRC32 ?? CRC32.hex(payloadData)).lowercased()
        self.payloadData = payloadData
    }

    /// Sanitizes an untrusted filename against path traversal, null bytes, and control characters.
    public static func sanitizeFileName(_ raw: String) -> String {
        let normalizedSeparators = raw.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedSeparators.split(separator: "/").map(String.init)
        let candidate = components.last(where: { !$0.isEmpty && $0 != "." && $0 != ".." }) ?? ""

        let filteredScalars = candidate.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        var cleaned = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "transfer.bin"
        }
        if cleaned.utf8.count > 255 {
            return String(cleaned.prefix(128))
        }
        return cleaned
    }

    /// Validates a session/file identifier string.
    public static func isValidFileID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }

    /// 직렬화하여 QR 코드에 담길 문자열 생성 (기본: protocolVersion에 따라 QRF1 또는 QRF2)
    public func serialize() -> String {
        if protocolVersion == 2 {
            return serializeV2()
        }
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

    /// QRF2 포맷으로 직렬화 (CRC32 및 플래그 포함)
    public func serializeV2() -> String {
        let fileNameBase64 = Data(fileName.utf8).base64EncodedString()
        let payloadBase64 = payloadData.base64EncodedString()
        return [
            Self.magicHeaderV2,
            fileID,
            String(chunkIndex),
            String(totalChunks),
            String(flags.rawValue),
            fileNameBase64,
            String(originalSize),
            sha256Prefix,
            chunkCRC32,
            payloadBase64
        ].joined(separator: "|")
    }

    /// QR 코드 텍스트로부터 패킷 역직렬화 (QRF1 및 QRF2 모두 지원, 악의적 입력 검증 포함)
    public static func deserialize(
        from text: String,
        maxTotalChunks: Int = defaultMaxTotalChunks,
        maxOriginalSize: Int = defaultMaxOriginalSize,
        maxChunkBytes: Int = defaultMaxChunkBytes
    ) -> TransferPacket? {
        let parts = text.components(separatedBy: "|")
        guard let header = parts.first else { return nil }

        if header == magicHeader {
            guard parts.count == 8 else { return nil }
            let fileID = parts[1]
            guard isValidFileID(fileID),
                  let chunkIndex = Int(parts[2]),
                  let totalChunks = Int(parts[3]),
                  totalChunks >= 1,
                  totalChunks <= maxTotalChunks,
                  chunkIndex >= 0,
                  chunkIndex < totalChunks,
                  let fileNameData = Data(base64Encoded: parts[4]),
                  fileNameData.count <= 1024,
                  let rawFileName = String(data: fileNameData, encoding: .utf8),
                  !rawFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let originalSize = Int(parts[5]),
                  originalSize >= 0,
                  originalSize <= maxOriginalSize,
                  let payloadData = Data(base64Encoded: parts[7]),
                  payloadData.count <= maxChunkBytes else {
                return nil
            }

            if originalSize > 0 && payloadData.isEmpty {
                return nil
            }

            let sha256Prefix = parts[6].lowercased()
            guard (sha256Prefix.count >= 8 && sha256Prefix.count <= 64),
                  sha256Prefix.allSatisfy({ $0.isHexDigit }) else {
                return nil
            }

            return TransferPacket(
                fileID: fileID,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                fileName: sanitizeFileName(rawFileName),
                originalSize: originalSize,
                sha256Prefix: sha256Prefix,
                payloadData: payloadData,
                protocolVersion: 1,
                flags: [.zlibCompressed]
            )
        } else if header == magicHeaderV2 {
            guard parts.count == 10 else { return nil }
            let fileID = parts[1]
            guard isValidFileID(fileID),
                  let chunkIndex = Int(parts[2]),
                  let totalChunks = Int(parts[3]),
                  totalChunks >= 1,
                  totalChunks <= maxTotalChunks,
                  chunkIndex >= 0,
                  chunkIndex < totalChunks,
                  let flagsRaw = UInt8(parts[4]),
                  let fileNameData = Data(base64Encoded: parts[5]),
                  fileNameData.count <= 1024,
                  let rawFileName = String(data: fileNameData, encoding: .utf8),
                  !rawFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let originalSize = Int(parts[6]),
                  originalSize >= 0,
                  originalSize <= maxOriginalSize,
                  let payloadData = Data(base64Encoded: parts[9]),
                  payloadData.count <= maxChunkBytes else {
                return nil
            }

            if originalSize > 0 && payloadData.isEmpty {
                return nil
            }

            let sha256Hex = parts[7].lowercased()
            guard (sha256Hex.count >= 8 && sha256Hex.count <= 64),
                  sha256Hex.allSatisfy({ $0.isHexDigit }) else {
                return nil
            }

            let crcHex = parts[8].lowercased()
            guard CRC32.verify(payloadData, expectedHex: crcHex) else {
                return nil
            }

            return TransferPacket(
                fileID: fileID,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                fileName: sanitizeFileName(rawFileName),
                originalSize: originalSize,
                sha256Prefix: sha256Hex,
                payloadData: payloadData,
                protocolVersion: 2,
                flags: PacketFlags(rawValue: flagsRaw),
                chunkCRC32: crcHex
            )
        }

        return nil
    }
}

/// 데이터 압축 및 해시 무결성 유틸리티
public nonisolated enum DataCompressor {
    /// 데이터를 zlib 압축 (실패하거나 압축 이득이 없으면 원본 반환)
    public static func compress(_ data: Data) -> Data {
        compressWithFlag(data).data
    }

    /// 데이터를 zlib 압축하고 실제로 압축이 적용되었는지 여부를 함께 반환
    public static func compressWithFlag(_ data: Data) -> (data: Data, isCompressed: Bool) {
        guard !data.isEmpty else { return (data, false) }
        do {
            let compressed = try (data as NSData).compressed(using: .zlib) as Data
            if compressed.count < data.count {
                return (compressed, true)
            }
            return (data, false)
        } catch {
            return (data, false)
        }
    }

    /// zlib 압축 해제 (기존 호환용 API: 압축되지 않은 데이터인 경우 원본 반환)
    public static func decompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            return data
        }
    }

    /// 크기 상한 및 예상 원본 크기를 검증하는 안전한 압축 해제
    public static func decompressBounded(
        _ data: Data,
        isCompressed: Bool,
        expectedSize: Int,
        maxOutputSize: Int = TransferPacket.defaultMaxOriginalSize
    ) -> Data? {
        guard expectedSize >= 0, expectedSize <= maxOutputSize else {
            return nil
        }
        if !isCompressed {
            guard data.count == expectedSize else { return nil }
            return data
        }
        if expectedSize == 0 {
            return data.isEmpty ? Data() : nil
        }
        if let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data {
            guard decompressed.count == expectedSize, decompressed.count <= maxOutputSize else {
                return nil
            }
            return decompressed
        }
        // QRF1 하위 호환: 압축 이득이 없어 원본이 그대로 전송된 경우 expectedSize와 일치하면 허용
        if data.count == expectedSize {
            return data
        }
        return nil
    }

    /// SHA-256 체크섬 계산 (앞 8자리 hex 반환)
    public static func sha256Prefix(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 전체 64자리 SHA-256 해시 hex 반환
    public static func sha256Hex(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 8자리 prefix 또는 전체 64자리 SHA-256 해시 일치 여부 검증
    public static func verifySHA256(_ data: Data, expectedHexOrPrefix: String) -> Bool {
        let normalized = expectedHexOrPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 8, normalized.count <= 64, normalized.allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        let fullHex = sha256Hex(for: data)
        return fullHex.hasPrefix(normalized)
    }
}

/// 전송 파일 메타데이터
public nonisolated struct TransferredFileInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Int
    public let data: Data
    public let transferDuration: TimeInterval

    public init(id: String, name: String, size: Int, data: Data, transferDuration: TimeInterval) {
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

/// Reassembly errors emitted by `TransferSessionAssembler`.
public nonisolated enum TransferReassemblyError: Error, Equatable, Sendable {
    case invalidFrame
    case metadataMismatch
    case missingChunk(Int)
    case checksumMismatch
    case decryptionRequired
    case decryptionFailed
    case decompressionFailed
}

/// Result of feeding a scanned QR frame into `TransferSessionAssembler`.
public nonisolated enum FrameIngestResult: Sendable, Equatable {
    case duplicate
    case accepted(received: Int, total: Int)
    case completed(TransferredFileInfo)
}

/// Standalone out-of-order reassembly engine supporting QRF1, QRF2, and QRFF fountain frames.
public nonisolated struct TransferSessionAssembler: Sendable {
    public private(set) var activeFileID: String?
    public private(set) var fileName: String = ""
    public private(set) var originalSize: Int = 0
    public private(set) var expectedSHA256: String = ""
    public private(set) var totalChunks: Int = 0
    public private(set) var flags: PacketFlags = [.zlibCompressed]
    public private(set) var protocolVersion: Int = 1
    public private(set) var receivedChunks: [Int: Data] = [:]
    public private(set) var fountainDecoder: FountainDecoder?

    public init() {}

    public mutating func reset() {
        activeFileID = nil
        fileName = ""
        originalSize = 0
        expectedSHA256 = ""
        totalChunks = 0
        flags = [.zlibCompressed]
        protocolVersion = 1
        receivedChunks.removeAll()
        fountainDecoder = nil
    }

    public var receivedCount: Int {
        if let decoder = fountainDecoder {
            return decoder.rank
        }
        return receivedChunks.count
    }

    public var progress: Double {
        guard totalChunks > 0 else { return 0 }
        return min(1.0, Double(receivedCount) / Double(totalChunks))
    }

    public var missingIndices: [Int] {
        guard totalChunks > 0, fountainDecoder == nil else { return [] }
        return (0..<totalChunks).filter { receivedChunks[$0] == nil }
    }

    /// Builds a sequence of QRF1 or QRF2 packets from raw file data.
    public static func encodePackets(
        fileName: String,
        data: Data,
        fileID: String = String(UUID().uuidString.prefix(6)).lowercased(),
        chunkSize: Int = 450,
        protocolVersion: Int = 2,
        passphrase: String? = nil
    ) throws -> [TransferPacket] {
        let effectiveChunkSize = max(16, min(chunkSize, TransferPacket.defaultMaxChunkBytes))
        let (compressedPayload, isCompressed) = DataCompressor.compressWithFlag(data)
        var flags: PacketFlags = isCompressed ? [.zlibCompressed] : []

        let framedData: Data
        if let passphrase, !passphrase.isEmpty {
            framedData = try EncryptedPayloadEnvelope.packBinary(
                plaintext: compressedPayload,
                passphrase: passphrase,
                context: fileID
            )
            flags.insert(.encryptedAESGCM)
        } else {
            framedData = compressedPayload
        }

        let sha = protocolVersion == 2
            ? DataCompressor.sha256Hex(for: framedData)
            : DataCompressor.sha256Prefix(for: framedData)

        let totalChunks = max(1, Int(ceil(Double(max(1, framedData.count)) / Double(effectiveChunkSize))))
        var packets: [TransferPacket] = []
        packets.reserveCapacity(totalChunks)

        for index in 0..<totalChunks {
            let start = index * effectiveChunkSize
            let end = min(start + effectiveChunkSize, framedData.count)
            let chunk = start < end ? framedData.subdata(in: start..<end) : Data()
            packets.append(
                TransferPacket(
                    fileID: fileID,
                    chunkIndex: index,
                    totalChunks: totalChunks,
                    fileName: fileName,
                    originalSize: data.count,
                    sha256Prefix: sha,
                    payloadData: chunk,
                    protocolVersion: protocolVersion,
                    flags: flags
                )
            )
        }

        return packets
    }

    /// Feeds a serialized QRF1, QRF2, or QRFF frame and returns progress or the reconstructed file.
    public mutating func ingest(
        frameText: String,
        passphrase: String? = nil,
        elapsedDuration: TimeInterval = 0.1
    ) throws -> FrameIngestResult {
        if frameText.hasPrefix(FountainDroplet.magicHeader + "|") {
            guard let droplet = FountainDroplet.deserialize(from: frameText) else {
                throw TransferReassemblyError.invalidFrame
            }
            return try ingestFountainDroplet(droplet, passphrase: passphrase, elapsedDuration: elapsedDuration)
        }

        guard let packet = TransferPacket.deserialize(from: frameText) else {
            throw TransferReassemblyError.invalidFrame
        }
        return try ingestPacket(packet, passphrase: passphrase, elapsedDuration: elapsedDuration)
    }

    public mutating func ingestPacket(
        _ packet: TransferPacket,
        passphrase: String? = nil,
        elapsedDuration: TimeInterval = 0.1
    ) throws -> FrameIngestResult {
        if activeFileID != packet.fileID || fountainDecoder != nil {
            reset()
            activeFileID = packet.fileID
            fileName = packet.fileName
            originalSize = packet.originalSize
            expectedSHA256 = packet.sha256Prefix
            totalChunks = packet.totalChunks
            flags = packet.flags
            protocolVersion = packet.protocolVersion
        } else {
            guard totalChunks == packet.totalChunks,
                  originalSize == packet.originalSize,
                  expectedSHA256 == packet.sha256Prefix,
                  protocolVersion == packet.protocolVersion else {
                throw TransferReassemblyError.metadataMismatch
            }
        }

        if let existing = receivedChunks[packet.chunkIndex] {
            if existing == packet.payloadData {
                return .duplicate
            } else {
                throw TransferReassemblyError.metadataMismatch
            }
        }

        receivedChunks[packet.chunkIndex] = packet.payloadData

        if receivedChunks.count < totalChunks {
            return .accepted(received: receivedChunks.count, total: totalChunks)
        }

        var merged = Data()
        for i in 0..<totalChunks {
            guard let chunk = receivedChunks[i] else {
                throw TransferReassemblyError.missingChunk(i)
            }
            merged.append(chunk)
        }

        let fileInfo = try finalizeStream(
            framedStream: merged,
            passphrase: passphrase,
            elapsedDuration: elapsedDuration
        )
        return .completed(fileInfo)
    }

    public mutating func ingestFountainDroplet(
        _ droplet: FountainDroplet,
        passphrase: String? = nil,
        elapsedDuration: TimeInterval = 0.1
    ) throws -> FrameIngestResult {
        if activeFileID != droplet.fileID || fountainDecoder == nil {
            reset()
            activeFileID = droplet.fileID
            fileName = droplet.fileName
            originalSize = droplet.originalSize
            expectedSHA256 = droplet.sha256Hex
            totalChunks = droplet.sourceBlocks
            flags = droplet.flags
            protocolVersion = 2
            fountainDecoder = FountainDecoder(
                fileID: droplet.fileID,
                sourceBlocks: droplet.sourceBlocks,
                blockSize: droplet.blockSize,
                streamLength: droplet.streamLength,
                originalSize: droplet.originalSize,
                sha256Hex: droplet.sha256Hex
            )
        }

        guard var decoder = fountainDecoder else {
            throw TransferReassemblyError.invalidFrame
        }

        let previousRank = decoder.rank
        let accepted = decoder.ingest(droplet)
        guard accepted else {
            throw TransferReassemblyError.metadataMismatch
        }
        fountainDecoder = decoder

        if let reconstructedStream = decoder.reconstructedStream() {
            let fileInfo = try finalizeStream(
                framedStream: reconstructedStream,
                passphrase: passphrase,
                elapsedDuration: elapsedDuration
            )
            return .completed(fileInfo)
        }

        if decoder.rank == previousRank {
            return .duplicate
        }
        return .accepted(received: decoder.rank, total: decoder.sourceBlocks)
    }

    private func finalizeStream(
        framedStream: Data,
        passphrase: String?,
        elapsedDuration: TimeInterval
    ) throws -> TransferredFileInfo {
        guard DataCompressor.verifySHA256(framedStream, expectedHexOrPrefix: expectedSHA256) else {
            throw TransferReassemblyError.checksumMismatch
        }

        let decryptedStream: Data
        if flags.contains(.encryptedAESGCM) {
            guard let passphrase, !passphrase.isEmpty else {
                throw TransferReassemblyError.decryptionRequired
            }
            do {
                decryptedStream = try EncryptedPayloadEnvelope.unpackBinary(
                    packed: framedStream,
                    passphrase: passphrase,
                    context: activeFileID ?? ""
                )
            } catch {
                throw TransferReassemblyError.decryptionFailed
            }
        } else {
            decryptedStream = framedStream
        }

        let isCompressed = protocolVersion == 1 ? true : flags.contains(.zlibCompressed)
        guard let finalData = DataCompressor.decompressBounded(
            decryptedStream,
            isCompressed: isCompressed,
            expectedSize: originalSize
        ) else {
            throw TransferReassemblyError.decompressionFailed
        }

        return TransferredFileInfo(
            id: activeFileID ?? UUID().uuidString,
            name: fileName,
            size: finalData.count,
            data: finalData,
            transferDuration: max(0.001, elapsedDuration)
        )
    }
}
