import Foundation

/// Deterministic SplitMix64 pseudo-random number generator for fountain droplet degree and block selection.
public nonisolated struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }
}

/// Luby Transform (LT) fountain erasure-coded droplet packet.
/// Format: QRFF|fileID|seed|sourceBlocks|blockSize|streamLength|originalSize|flags|fileNameBase64|sha256Hex|crc32Hex|payloadBase64
public nonisolated struct FountainDroplet: Sendable, Equatable {
    public static let magicHeader = "QRFF"
    public static let maxSourceBlocks = 2_048
    public static let maxBlockSize = 8_192

    public let fileID: String
    public let seed: UInt32
    public let sourceBlocks: Int
    public let blockSize: Int
    public let streamLength: Int
    public let originalSize: Int
    public let flags: PacketFlags
    public let fileName: String
    public let sha256Hex: String
    public let crc32Hex: String
    public let payloadData: Data

    public init(
        fileID: String,
        seed: UInt32,
        sourceBlocks: Int,
        blockSize: Int,
        streamLength: Int,
        originalSize: Int,
        flags: PacketFlags,
        fileName: String,
        sha256Hex: String,
        crc32Hex: String? = nil,
        payloadData: Data
    ) {
        self.fileID = fileID
        self.seed = seed
        self.sourceBlocks = sourceBlocks
        self.blockSize = blockSize
        self.streamLength = streamLength
        self.originalSize = originalSize
        self.flags = flags
        self.fileName = TransferPacket.sanitizeFileName(fileName)
        self.sha256Hex = sha256Hex.lowercased()
        self.crc32Hex = (crc32Hex ?? CRC32.hex(payloadData)).lowercased()
        self.payloadData = payloadData
    }

    public func serialize() -> String {
        let fileNameBase64 = Data(fileName.utf8).base64EncodedString()
        let payloadBase64 = payloadData.base64EncodedString()
        return [
            Self.magicHeader,
            fileID,
            String(seed),
            String(sourceBlocks),
            String(blockSize),
            String(streamLength),
            String(originalSize),
            String(flags.rawValue),
            fileNameBase64,
            sha256Hex,
            crc32Hex,
            payloadBase64
        ].joined(separator: "|")
    }

    public static func deserialize(
        from text: String,
        maxOriginalSize: Int = TransferPacket.defaultMaxOriginalSize
    ) -> FountainDroplet? {
        let parts = text.components(separatedBy: "|")
        guard parts.count == 12, parts[0] == magicHeader else {
            return nil
        }

        let fileID = parts[1]
        guard TransferPacket.isValidFileID(fileID),
              let seed = UInt32(parts[2]),
              let sourceBlocks = Int(parts[3]),
              sourceBlocks >= 1,
              sourceBlocks <= maxSourceBlocks,
              let blockSize = Int(parts[4]),
              blockSize >= 1,
              blockSize <= maxBlockSize,
              let streamLength = Int(parts[5]),
              streamLength >= 0,
              streamLength <= sourceBlocks * blockSize,
              let originalSize = Int(parts[6]),
              originalSize >= 0,
              originalSize <= maxOriginalSize,
              let flagsRaw = UInt8(parts[7]),
              let fileNameData = Data(base64Encoded: parts[8]),
              fileNameData.count <= 1024,
              let rawFileName = String(data: fileNameData, encoding: .utf8),
              !rawFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payloadData = Data(base64Encoded: parts[11]),
              payloadData.count == blockSize else {
            return nil
        }

        let shaHex = parts[9].lowercased()
        guard shaHex.count >= 8, shaHex.count <= 64, shaHex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        let crcHex = parts[10].lowercased()
        guard CRC32.verify(payloadData, expectedHex: crcHex) else {
            return nil
        }

        return FountainDroplet(
            fileID: fileID,
            seed: seed,
            sourceBlocks: sourceBlocks,
            blockSize: blockSize,
            streamLength: streamLength,
            originalSize: originalSize,
            flags: PacketFlags(rawValue: flagsRaw),
            fileName: TransferPacket.sanitizeFileName(rawFileName),
            sha256Hex: shaHex,
            crc32Hex: crcHex,
            payloadData: payloadData
        )
    }
}

/// Systematic + Luby Transform (LT) fountain encoder for loss-resilient multi-QR streaming.
public nonisolated struct FountainEncoder: Sendable {
    public let fileID: String
    public let fileName: String
    public let originalSize: Int
    public let streamLength: Int
    public let blockSize: Int
    public let sourceBlocks: Int
    public let flags: PacketFlags
    public let sha256Hex: String
    private let blocks: [[UInt8]]

    public init(
        fileName: String,
        rawFileData: Data,
        fileID: String = String(UUID().uuidString.prefix(6)).lowercased(),
        blockSize: Int = 450,
        passphrase: String? = nil
    ) throws {
        let effectiveBlockSize = max(16, min(blockSize, FountainDroplet.maxBlockSize))
        let (compressed, isCompressed) = DataCompressor.compressWithFlag(rawFileData)
        var packetFlags: PacketFlags = [.fountainCoded]
        if isCompressed {
            packetFlags.insert(.zlibCompressed)
        }

        let streamData: Data
        if let passphrase, !passphrase.isEmpty {
            streamData = try EncryptedPayloadEnvelope.packBinary(
                plaintext: compressed,
                passphrase: passphrase,
                context: fileID
            )
            packetFlags.insert(.encryptedAESGCM)
        } else {
            streamData = compressed
        }

        let k = max(1, Int(ceil(Double(max(1, streamData.count)) / Double(effectiveBlockSize))))
        var slicedBlocks: [[UInt8]] = []
        slicedBlocks.reserveCapacity(k)

        let streamBytes = [UInt8](streamData)
        for index in 0..<k {
            let start = index * effectiveBlockSize
            let end = min(start + effectiveBlockSize, streamBytes.count)
            var block = [UInt8](repeating: 0, count: effectiveBlockSize)
            if start < end {
                for i in start..<end {
                    block[i - start] = streamBytes[i]
                }
            }
            slicedBlocks.append(block)
        }

        self.fileID = fileID
        self.fileName = TransferPacket.sanitizeFileName(fileName)
        self.originalSize = rawFileData.count
        self.streamLength = streamData.count
        self.blockSize = effectiveBlockSize
        self.sourceBlocks = k
        self.flags = packetFlags
        self.sha256Hex = DataCompressor.sha256Hex(for: streamData)
        self.blocks = slicedBlocks
    }

    /// Deterministically computes the source block indices combined into a droplet for `seed`.
    /// Seeds `0..<sourceBlocks` are systematic degree-1 blocks; seeds `>= sourceBlocks` sample
    /// a tuned LT degree distribution so any K linearly independent droplets solve all blocks.
    public static func selectedIndices(forSeed seed: UInt32, sourceBlocks: Int) -> [Int] {
        precondition(sourceBlocks >= 1)
        if sourceBlocks == 1 {
            return [0]
        }
        if Int(seed) < sourceBlocks {
            return [Int(seed)]
        }

        var rng = SplitMix64(seed: UInt64(seed) ^ (UInt64(sourceBlocks) &<< 32) ^ 0xA5A5_5A5A_F0F0_0F0F)
        let bucket = Int(rng.next() % 100)
        let rawDegree: Int
        if bucket < 12 {
            rawDegree = 1
        } else if bucket < 45 {
            rawDegree = 2
        } else if bucket < 70 {
            rawDegree = 3
        } else if bucket < 85 {
            rawDegree = 4
        } else if bucket < 95 {
            rawDegree = max(2, (sourceBlocks + 1) / 2)
        } else {
            rawDegree = max(2, min(sourceBlocks, 8))
        }
        let degree = max(1, min(sourceBlocks, rawDegree))

        var chosen = Set<Int>()
        chosen.reserveCapacity(degree)
        while chosen.count < degree {
            chosen.insert(rng.nextInt(upperBound: sourceBlocks))
        }
        return chosen.sorted()
    }

    /// Generates a single encoded fountain droplet for `seed`.
    public func makeDroplet(seed: UInt32) -> FountainDroplet {
        let indices = Self.selectedIndices(forSeed: seed, sourceBlocks: sourceBlocks)
        var xorBuffer = [UInt8](repeating: 0, count: blockSize)
        for idx in indices {
            let block = blocks[idx]
            for byteIndex in 0..<blockSize {
                xorBuffer[byteIndex] ^= block[byteIndex]
            }
        }

        return FountainDroplet(
            fileID: fileID,
            seed: seed,
            sourceBlocks: sourceBlocks,
            blockSize: blockSize,
            streamLength: streamLength,
            originalSize: originalSize,
            flags: flags,
            fileName: fileName,
            sha256Hex: sha256Hex,
            payloadData: Data(xorBuffer)
        )
    }

    /// Generates `count` fountain droplets starting from `startSeed`.
    public func makeDroplets(count: Int, startSeed: UInt32 = 0) -> [FountainDroplet] {
        guard count > 0 else { return [] }
        return (0..<count).map { offset in
            makeDroplet(seed: startSeed &+ UInt32(offset))
        }
    }
}

/// Incremental Gauss-Jordan + Peeling decoder over GF(2) for Luby Transform fountain droplets.
public nonisolated struct FountainDecoder: Sendable {
    public let fileID: String
    public let sourceBlocks: Int
    public let blockSize: Int
    public let streamLength: Int
    public let originalSize: Int
    public let sha256Hex: String

    private struct EquationRow: Sendable {
        var indices: Set<Int>
        var payload: [UInt8]
    }

    private var pivots: [Int: EquationRow] = [:]

    public init(
        fileID: String,
        sourceBlocks: Int,
        blockSize: Int,
        streamLength: Int,
        originalSize: Int,
        sha256Hex: String
    ) {
        self.fileID = fileID
        self.sourceBlocks = sourceBlocks
        self.blockSize = blockSize
        self.streamLength = streamLength
        self.originalSize = originalSize
        self.sha256Hex = sha256Hex.lowercased()
    }

    /// Number of linearly independent droplets collected so far (`0...sourceBlocks`).
    public var rank: Int {
        pivots.count
    }

    /// Number of individual source blocks already isolated to degree 1.
    public var solvedBlockCount: Int {
        pivots.values.filter { $0.indices.count == 1 }.count
    }

    /// True once `rank == sourceBlocks` (all source blocks are solved).
    public var isComplete: Bool {
        pivots.count == sourceBlocks
    }

    /// Ingests a fountain droplet and performs incremental Gauss-Jordan reduction over GF(2).
    /// Returns `false` if the droplet metadata does not match this decoding session.
    public mutating func ingest(_ droplet: FountainDroplet) -> Bool {
        guard droplet.fileID == fileID,
              droplet.sourceBlocks == sourceBlocks,
              droplet.blockSize == blockSize,
              droplet.streamLength == streamLength,
              droplet.originalSize == originalSize,
              droplet.sha256Hex.lowercased() == sha256Hex,
              droplet.payloadData.count == blockSize,
              CRC32.verify(droplet.payloadData, expectedHex: droplet.crc32Hex) else {
            return false
        }

        if isComplete {
            return true
        }

        let selected = FountainEncoder.selectedIndices(forSeed: droplet.seed, sourceBlocks: sourceBlocks)
        var rowIndices = Set(selected)
        var rowPayload = [UInt8](droplet.payloadData)

        // Forward elimination against existing pivot columns
        while let minCol = rowIndices.min() {
            if let existingPivot = pivots[minCol] {
                rowIndices.formSymmetricDifference(existingPivot.indices)
                xorBytes(&rowPayload, with: existingPivot.payload)
            } else {
                // Eliminate any higher columns in rowIndices that already have pivots
                let otherCols = rowIndices.filter { $0 != minCol }.sorted()
                for col in otherCols {
                    if let otherPivot = pivots[col] {
                        rowIndices.formSymmetricDifference(otherPivot.indices)
                        xorBytes(&rowPayload, with: otherPivot.payload)
                    }
                }

                let newPivotRow = EquationRow(indices: rowIndices, payload: rowPayload)
                pivots[minCol] = newPivotRow

                // Back-substitution into existing pivots that reference minCol
                let existingKeys = Array(pivots.keys)
                for key in existingKeys where key != minCol {
                    if var existing = pivots[key], existing.indices.contains(minCol) {
                        existing.indices.formSymmetricDifference(newPivotRow.indices)
                        xorBytes(&existing.payload, with: newPivotRow.payload)
                        pivots[key] = existing
                    }
                }
                break
            }
        }

        return true
    }

    /// Returns the reconstructed unpadded stream Data once `isComplete` is true, or `nil` otherwise.
    public func reconstructedStream() -> Data? {
        guard isComplete else { return nil }
        var output = Data()
        output.reserveCapacity(sourceBlocks * blockSize)
        for blockIndex in 0..<sourceBlocks {
            guard let pivot = pivots[blockIndex], pivot.indices.count == 1, pivot.indices.contains(blockIndex) else {
                return nil
            }
            output.append(contentsOf: pivot.payload)
        }
        if output.count > streamLength {
            return output.prefix(streamLength)
        }
        return output
    }

    private func xorBytes(_ target: inout [UInt8], with source: [UInt8]) {
        for i in 0..<target.count {
            target[i] ^= source[i]
        }
    }
}
