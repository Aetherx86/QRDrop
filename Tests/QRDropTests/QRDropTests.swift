import XCTest
@testable import QRDropCore

final class QRDropTests: XCTestCase {

    func testVersionConstant() {
        XCTAssertEqual(QRDropVersion.current, "0.2.0")
    }

    func testCRC32StandardVectors() {
        let empty = Data()
        XCTAssertEqual(CRC32.checksum(empty), 0x00000000)
        XCTAssertEqual(CRC32.hex(empty), "00000000")

        let standard = Data("123456789".utf8)
        XCTAssertEqual(CRC32.checksum(standard), 0xCBF43926)
        XCTAssertEqual(CRC32.hex(standard), "cbf43926")
        XCTAssertTrue(CRC32.verify(standard, expectedHex: "CBF43926"))
        XCTAssertFalse(CRC32.verify(standard, expectedHex: "cbf43927"))
        XCTAssertFalse(CRC32.verify(standard, expectedHex: "not-hex!"))
        XCTAssertFalse(CRC32.verify(standard, expectedHex: "1234"))
    }

    func testTransferPacketV1BackwardCompatibility() {
        let payload = Data("Hello offline optical transfer".utf8)
        let shaPrefix = DataCompressor.sha256Prefix(for: payload)
        XCTAssertEqual(shaPrefix.count, 8)

        let packet = TransferPacket(
            fileID: "abc123",
            chunkIndex: 0,
            totalChunks: 1,
            fileName: "memo.txt",
            originalSize: payload.count,
            sha256Prefix: shaPrefix,
            payloadData: payload
        )
        let raw = packet.serialize()
        XCTAssertTrue(raw.hasPrefix("QRF1|abc123|0|1|"))

        let parsed = TransferPacket.deserialize(from: raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.protocolVersion, 1)
        XCTAssertEqual(parsed?.fileID, "abc123")
        XCTAssertEqual(parsed?.chunkIndex, 0)
        XCTAssertEqual(parsed?.totalChunks, 1)
        XCTAssertEqual(parsed?.fileName, "memo.txt")
        XCTAssertEqual(parsed?.originalSize, payload.count)
        XCTAssertEqual(parsed?.sha256Prefix, shaPrefix)
        XCTAssertEqual(parsed?.payloadData, payload)
    }

    func testTransferPacketV2RoundTripAndTamperRejection() {
        let payload = Data("Protocol v2 frame payload with CRC32".utf8)
        let fullSHA = DataCompressor.sha256Hex(for: payload)
        XCTAssertEqual(fullSHA.count, 64)

        let packet = TransferPacket(
            fileID: "v2file",
            chunkIndex: 2,
            totalChunks: 5,
            fileName: "report.pdf",
            originalSize: 2048,
            sha256Prefix: fullSHA,
            payloadData: payload,
            protocolVersion: 2,
            flags: [.zlibCompressed, .encryptedAESGCM]
        )

        let raw = packet.serialize()
        XCTAssertTrue(raw.hasPrefix("QRF2|v2file|2|5|"))

        let decoded = TransferPacket.deserialize(from: raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.protocolVersion, 2)
        XCTAssertEqual(decoded?.flags, [.zlibCompressed, .encryptedAESGCM])
        XCTAssertEqual(decoded?.chunkCRC32, CRC32.hex(payload))
        XCTAssertEqual(decoded?.payloadData, payload)

        // Corrupt the CRC32 field and verify immediate rejection
        var parts = raw.components(separatedBy: "|")
        parts[8] = "00000000"
        let corruptedCRC = parts.joined(separator: "|")
        XCTAssertNil(TransferPacket.deserialize(from: corruptedCRC))
    }

    func testHostilePacketInputsAndPathTraversalSanitization() {
        XCTAssertEqual(TransferPacket.sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(TransferPacket.sanitizeFileName("..\\..\\Windows\\System32\\cmd.exe"), "cmd.exe")
        XCTAssertEqual(TransferPacket.sanitizeFileName("..."), "transfer.bin")
        XCTAssertEqual(TransferPacket.sanitizeFileName("   "), "transfer.bin")
        XCTAssertEqual(TransferPacket.sanitizeFileName(".hidden_config.json"), "hidden_config.json")
        XCTAssertEqual(TransferPacket.sanitizeFileName("bad\0name\n.txt"), "badname.txt")

        let validNameB64 = Data("test.txt".utf8).base64EncodedString()
        let validPayloadB64 = Data("abc".utf8).base64EncodedString()

        // Negative chunk index
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|-1|3|\(validNameB64)|3|12345678|\(validPayloadB64)"))
        // chunkIndex >= totalChunks
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|3|3|\(validNameB64)|3|12345678|\(validPayloadB64)"))
        // totalChunks == 0
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|0|0|\(validNameB64)|3|12345678|\(validPayloadB64)"))
        // totalChunks exceeds cap
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|0|999999|\(validNameB64)|3|12345678|\(validPayloadB64)"))
        // Negative originalSize
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|0|1|\(validNameB64)|-5|12345678|\(validPayloadB64)"))
        // Non-hex SHA256
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|id1|0|1|\(validNameB64)|3|zzzzzzzz|\(validPayloadB64)"))
        // Invalid fileID with path separator
        XCTAssertNil(TransferPacket.deserialize(from: "QRF1|../id|0|1|\(validNameB64)|3|12345678|\(validPayloadB64)"))
    }

    func testOutOfOrderAndDuplicateSessionReassembly() throws {
        var rng = SplitMix64(seed: 0x1234_5678_9ABC_DEF0)
        var text = ""
        for idx in 0..<120 {
            text += "QRDrop line \(idx) token \(String(format: "%016llx", rng.next()))\n"
        }
        let originalData = Data(text.utf8)

        let packets = try TransferSessionAssembler.encodePackets(
            fileName: "../unsafe/path/document.txt",
            data: originalData,
            fileID: "sess01",
            chunkSize: 128,
            protocolVersion: 2
        )
        XCTAssertGreaterThan(packets.count, 5)
        XCTAssertEqual(packets.first?.fileName, "document.txt")

        var assembler = TransferSessionAssembler()
        var reversed = Array(packets.reversed())
        // Duplicate the first and middle elements
        reversed.insert(reversed[0], at: 1)

        var completed: TransferredFileInfo?
        var duplicateCount = 0

        for pkt in reversed {
            let result = try assembler.ingest(frameText: pkt.serialize())
            switch result {
            case .duplicate:
                duplicateCount += 1
            case .accepted:
                break
            case .completed(let info):
                completed = info
            }
        }

        XCTAssertEqual(duplicateCount, 1)
        XCTAssertNotNil(completed)
        XCTAssertEqual(completed?.name, "document.txt")
        XCTAssertEqual(completed?.data, originalData)
    }

    func testFountainCodingRecoveryUnderPacketLossAndPermutation() throws {
        var payload = Data()
        for i in 0..<400 {
            payload.append(Data("FountainBlock-\(i)-PayloadData-0123456789ABCDEF\n".utf8))
        }

        let encoder = try FountainEncoder(
            fileName: "fountain_stream.log",
            rawFileData: payload,
            fileID: "fnt001",
            blockSize: 180
        )
        XCTAssertGreaterThan(encoder.sourceBlocks, 4)

        // Generate 2.2x droplets, drop every 3rd droplet (including systematic frames), and shuffle
        let allDroplets = encoder.makeDroplets(count: encoder.sourceBlocks * 2 + 12)
        var surviving: [FountainDroplet] = []
        for (idx, d) in allDroplets.enumerated() where idx % 3 != 0 {
            surviving.append(d)
        }
        // Deterministic permutation
        surviving.reverse()

        var assembler = TransferSessionAssembler()
        var reconstructed: TransferredFileInfo?

        for droplet in surviving {
            let serialized = droplet.serialize()
            let res = try assembler.ingest(frameText: serialized)
            if case .completed(let info) = res {
                reconstructed = info
                break
            }
        }

        XCTAssertNotNil(reconstructed)
        XCTAssertEqual(reconstructed?.name, "fountain_stream.log")
        XCTAssertEqual(reconstructed?.data, payload)
    }

    func testEncryptedPayloadEnvelopeRoundTripAndTamperDetection() throws {
        let secret = Data("Classified air-gapped QR payload".utf8)
        let envelope = try EncryptedPayloadEnvelope.seal(
            plaintext: secret,
            passphrase: "correct-horse-battery-staple",
            context: "session-42"
        )

        let wire = envelope.serialize()
        let parsed = try EncryptedPayloadEnvelope.deserialize(from: wire)
        let opened = try parsed.open(passphrase: "correct-horse-battery-staple", context: "session-42")
        XCTAssertEqual(opened, secret)

        // Wrong passphrase must fail authentication
        XCTAssertThrowsError(try parsed.open(passphrase: "wrong-passphrase", context: "session-42")) { err in
            XCTAssertEqual(err as? CryptoEnvelopeError, .authenticationFailed)
        }

        // Wrong context (AAD mismatch) must fail authentication
        XCTAssertThrowsError(try parsed.open(passphrase: "correct-horse-battery-staple", context: "session-99")) { err in
            XCTAssertEqual(err as? CryptoEnvelopeError, .authenticationFailed)
        }

        // Bit-flip in ciphertext must fail authentication
        var tamperedCipher = parsed.ciphertext
        tamperedCipher[0] ^= 0xFF
        let tamperedEnvelope = try EncryptedPayloadEnvelope(
            salt: parsed.salt,
            nonce: parsed.nonce,
            tag: parsed.tag,
            ciphertext: tamperedCipher
        )
        XCTAssertThrowsError(try tamperedEnvelope.open(passphrase: "correct-horse-battery-staple", context: "session-42")) { err in
            XCTAssertEqual(err as? CryptoEnvelopeError, .authenticationFailed)
        }

        // Empty passphrase must throw .emptyPassphrase
        XCTAssertThrowsError(try EncryptedPayloadEnvelope.seal(plaintext: secret, passphrase: "")) { err in
            XCTAssertEqual(err as? CryptoEnvelopeError, .emptyPassphrase)
        }
    }

    func testEncryptedMultiFrameAndFountainSessionAssembly() throws {
        let original = Data(String(repeating: "Encrypted fountain optical transfer payload.\n", count: 80).utf8)
        let encoder = try FountainEncoder(
            fileName: "vault.bin",
            rawFileData: original,
            fileID: "encfnt",
            blockSize: 120,
            passphrase: "optical-key-2026"
        )
        let droplets = encoder.makeDroplets(count: encoder.sourceBlocks + 6)

        // Attempt assembly without passphrase -> must throw .decryptionRequired
        var noKeyAssembler = TransferSessionAssembler()
        var threwDecryptionRequired = false
        for d in droplets {
            do {
                _ = try noKeyAssembler.ingestFountainDroplet(d, passphrase: nil)
            } catch TransferReassemblyError.decryptionRequired {
                threwDecryptionRequired = true
                break
            }
        }
        XCTAssertTrue(threwDecryptionRequired)

        // Attempt assembly with wrong passphrase -> must throw .decryptionFailed
        var badKeyAssembler = TransferSessionAssembler()
        var threwDecryptionFailed = false
        for d in droplets {
            do {
                _ = try badKeyAssembler.ingestFountainDroplet(d, passphrase: "wrong-key")
            } catch TransferReassemblyError.decryptionFailed {
                threwDecryptionFailed = true
                break
            }
        }
        XCTAssertTrue(threwDecryptionFailed)

        // Assemble with valid passphrase
        var validAssembler = TransferSessionAssembler()
        var recovered: Data?
        for d in droplets {
            if case .completed(let info) = try validAssembler.ingestFountainDroplet(d, passphrase: "optical-key-2026") {
                recovered = info.data
                break
            }
        }
        XCTAssertEqual(recovered, original)
    }

    func testWiFiPayloadEncodingEscapingAndValidation() throws {
        let wifi = try WiFiPayload(
            ssid: "Lab;Net:5G",
            password: "p\\w;123:45",
            authentication: .wpa,
            isHidden: true
        )
        let encoded = wifi.encode()
        XCTAssertEqual(encoded, "WIFI:T:WPA;S:Lab\\;Net\\:5G;P:p\\\\w\\;123\\:45;H:true;;")

        let decoded = try WiFiPayload.parse(encoded)
        XCTAssertEqual(decoded, wifi)

        // Open network (nopass)
        let guest = try WiFiPayload(ssid: "GuestWiFi", password: "", authentication: .nopass)
        XCTAssertEqual(guest.encode(), "WIFI:T:nopass;S:GuestWiFi;;")
        XCTAssertEqual(try WiFiPayload.parse(guest.encode()), guest)

        // Hostile / invalid inputs
        XCTAssertThrowsError(try WiFiPayload(ssid: "", password: "secret", authentication: .wpa))
        XCTAssertThrowsError(try WiFiPayload(ssid: String(repeating: "A", count: 33), password: "secret", authentication: .wpa))
        XCTAssertThrowsError(try WiFiPayload(ssid: "OpenNet", password: "non-empty-on-nopass", authentication: .nopass))
        XCTAssertThrowsError(try WiFiPayload(ssid: "SecureNet", password: "", authentication: .wpa))
        XCTAssertThrowsError(try WiFiPayload(ssid: "Bad\nSSID", password: "secret", authentication: .wpa))
    }

    func testVCardPayloadRoundTripAndValidation() throws {
        let card = try VCardPayload(
            fullName: "Jeong Hoon Kim",
            organization: "QRDrop Optical Lab; Division 1",
            title: "Systems Engineer",
            phone: "+82-10-1234-5678",
            email: "contact@example.com",
            url: "https://example.com/qrdrop",
            note: "Line 1\nLine 2"
        )
        let encoded = card.encode()
        let parsed = try VCardPayload.parse(encoded)
        XCTAssertEqual(parsed, card)

        // Reject invalid email, empty name, or forbidden URI inside vCard
        XCTAssertThrowsError(try VCardPayload(fullName: "   "))
        XCTAssertThrowsError(try VCardPayload(fullName: "Alice", email: "not-an-email"))
        XCTAssertThrowsError(try VCardPayload(fullName: "Alice", url: "javascript:alert(1)"))
    }

    func testURIPayloadAndInspectorClassification() throws {
        let httpsURI = try URIPayload(rawValue: "https://github.com/Aetherx86/QRDrop")
        XCTAssertEqual(httpsURI.scheme, "https")

        XCTAssertThrowsError(try URIPayload(rawValue: "javascript:alert(1)")) { err in
            XCTAssertEqual(err as? StructuredPayloadError, .forbiddenURIScheme("javascript"))
        }
        XCTAssertThrowsError(try URIPayload(rawValue: "data:text/html,<script>alert(1)</script>"))
        XCTAssertThrowsError(try URIPayload(rawValue: "file:///etc/passwd"))
        XCTAssertThrowsError(try URIPayload(rawValue: "https://example.com/with space"))

        // Inspector classification across all supported payload kinds
        let wifiStr = try WiFiPayload(ssid: "Office", password: "secretpassword", authentication: .wpa).encode()
        XCTAssertEqual(QRPayloadInspector.inspect(wifiStr).typeIdentifier, "wifi")

        let vcardStr = try VCardPayload(fullName: "Hong Gil Dong", email: "hgd@example.com").encode()
        XCTAssertEqual(QRPayloadInspector.inspect(vcardStr).typeIdentifier, "vcard")

        let envStr = try EncryptedPayloadEnvelope.seal(plaintext: Data("hi".utf8), passphrase: "pw").serialize()
        XCTAssertEqual(QRPayloadInspector.inspect(envStr).typeIdentifier, "qre1")

        let pktV1 = TransferPacket(
            fileID: "id1",
            chunkIndex: 0,
            totalChunks: 1,
            fileName: "a.txt",
            originalSize: 2,
            sha256Prefix: "12345678",
            payloadData: Data("hi".utf8),
            protocolVersion: 1
        ).serialize()
        XCTAssertEqual(QRPayloadInspector.inspect(pktV1).typeIdentifier, "qrf1")

        let pktV2 = TransferPacket(
            fileID: "id2",
            chunkIndex: 0,
            totalChunks: 1,
            fileName: "a.txt",
            originalSize: 2,
            sha256Prefix: "12345678",
            payloadData: Data("hi".utf8),
            protocolVersion: 2
        ).serialize()
        XCTAssertEqual(QRPayloadInspector.inspect(pktV2).typeIdentifier, "qrf2")

        let dropletStr = try FountainEncoder(
            fileName: "a.txt",
            rawFileData: Data("hi".utf8),
            fileID: "id3"
        ).makeDroplet(seed: 0).serialize()
        XCTAssertEqual(QRPayloadInspector.inspect(dropletStr).typeIdentifier, "qrff")

        XCTAssertEqual(QRPayloadInspector.inspect("https://example.com").typeIdentifier, "uri")
        XCTAssertEqual(QRPayloadInspector.inspect("Plain memo text").typeIdentifier, "text")
    }

    @MainActor
    func testQRGeneratorAndReceiverViewModelIntegration() throws {
        let image = QRGenerator.makeQRCode(from: "QRDrop v0.2.0 optical test", targetSize: 256)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.width, 256)
        XCTAssertEqual(image?.height, 256)

        let payload = Data(String(repeating: "ReceiverViewModel fountain integration test.\n", count: 30).utf8)
        let encoder = try FountainEncoder(
            fileName: "vm_test.txt",
            rawFileData: payload,
            fileID: "vmfnt1",
            blockSize: 100,
            passphrase: "vm-secret"
        )
        let droplets = encoder.makeDroplets(count: encoder.sourceBlocks + 5).reversed()

        let receiverVM = ReceiverViewModel()
        receiverVM.decryptionPassphrase = "vm-secret"

        for droplet in droplets {
            receiverVM.processScannedCode(droplet.serialize())
            if receiverVM.completedFile != nil {
                break
            }
        }

        XCTAssertNotNil(receiverVM.completedFile)
        XCTAssertEqual(receiverVM.completedFile?.name, "vm_test.txt")
        XCTAssertEqual(receiverVM.completedFile?.data, payload)
        XCTAssertEqual(receiverVM.progress, 1.0, accuracy: 0.001)
    }
}
