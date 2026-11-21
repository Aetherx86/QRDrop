import Foundation
import CryptoKit

/// Errors thrown during encrypted QR payload envelope operations.
public nonisolated enum CryptoEnvelopeError: Error, Equatable, Sendable {
    case emptyPassphrase
    case invalidFormat
    case invalidSaltLength
    case invalidNonceLength
    case invalidTagLength
    case authenticationFailed
    case encryptionFailed
}

/// Authenticated encrypted payload envelope using HKDF-SHA256 key derivation and AES-GCM-256.
/// String Wire Format: QRE1|<saltBase64>|<nonceBase64>|<tagBase64>|<ciphertextBase64>
/// Binary Wire Format: [4B "QRE1"][16B salt][12B nonce][16B tag][ciphertext...]
public nonisolated struct EncryptedPayloadEnvelope: Sendable, Equatable {
    public static let magicHeader = "QRE1"
    public static let saltByteCount = 16
    public static let nonceByteCount = 12
    public static let tagByteCount = 16
    private static let domainInfoPrefix = "QRDrop-v0.2-AES256GCM"

    public let salt: Data
    public let nonce: Data
    public let tag: Data
    public let ciphertext: Data

    public init(salt: Data, nonce: Data, tag: Data, ciphertext: Data) throws {
        guard salt.count == Self.saltByteCount else {
            throw CryptoEnvelopeError.invalidSaltLength
        }
        guard nonce.count == Self.nonceByteCount else {
            throw CryptoEnvelopeError.invalidNonceLength
        }
        guard tag.count == Self.tagByteCount else {
            throw CryptoEnvelopeError.invalidTagLength
        }
        self.salt = salt
        self.nonce = nonce
        self.tag = tag
        self.ciphertext = ciphertext
    }

    /// Derives a 256-bit symmetric key from a passphrase, 16-byte salt, and domain context via HKDF-SHA256.
    public static func deriveKey(passphrase: String, salt: Data, context: String = "") throws -> SymmetricKey {
        guard !passphrase.isEmpty else {
            throw CryptoEnvelopeError.emptyPassphrase
        }
        guard salt.count == saltByteCount else {
            throw CryptoEnvelopeError.invalidSaltLength
        }
        let ikm = SymmetricKey(data: Data(passphrase.utf8))
        let info = Data("\(domainInfoPrefix)|\(context)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// Encrypts plaintext into an `EncryptedPayloadEnvelope` with HKDF-SHA256 and AES-GCM-256.
    public static func seal(
        plaintext: Data,
        passphrase: String,
        context: String = "",
        salt: Data? = nil,
        nonce: Data? = nil
    ) throws -> EncryptedPayloadEnvelope {
        guard !passphrase.isEmpty else {
            throw CryptoEnvelopeError.emptyPassphrase
        }

        let effectiveSalt: Data
        if let salt {
            guard salt.count == saltByteCount else {
                throw CryptoEnvelopeError.invalidSaltLength
            }
            effectiveSalt = salt
        } else {
            effectiveSalt = randomBytes(count: saltByteCount)
        }

        let effectiveNonceData: Data
        if let nonce {
            guard nonce.count == nonceByteCount else {
                throw CryptoEnvelopeError.invalidNonceLength
            }
            effectiveNonceData = nonce
        } else {
            effectiveNonceData = randomBytes(count: nonceByteCount)
        }

        let key = try deriveKey(passphrase: passphrase, salt: effectiveSalt, context: context)
        let gcmNonce: AES.GCM.Nonce
        do {
            gcmNonce = try AES.GCM.Nonce(data: effectiveNonceData)
        } catch {
            throw CryptoEnvelopeError.invalidNonceLength
        }

        let aad = makeAAD(salt: effectiveSalt, nonce: effectiveNonceData, context: context)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: gcmNonce, authenticating: aad)
        } catch {
            throw CryptoEnvelopeError.encryptionFailed
        }

        return try EncryptedPayloadEnvelope(
            salt: effectiveSalt,
            nonce: effectiveNonceData,
            tag: sealedBox.tag,
            ciphertext: sealedBox.ciphertext
        )
    }

    /// Decrypts and authenticates the envelope using the supplied passphrase and context.
    public func open(passphrase: String, context: String = "") throws -> Data {
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, context: context)
        let gcmNonce: AES.GCM.Nonce
        do {
            gcmNonce = try AES.GCM.Nonce(data: nonce)
        } catch {
            throw CryptoEnvelopeError.invalidNonceLength
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw CryptoEnvelopeError.invalidFormat
        }

        let aad = Self.makeAAD(salt: salt, nonce: nonce, context: context)
        do {
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw CryptoEnvelopeError.authenticationFailed
        }
    }

    /// Serializes the envelope into `QRE1|<saltB64>|<nonceB64>|<tagB64>|<ciphertextB64>`.
    public func serialize() -> String {
        [
            Self.magicHeader,
            salt.base64EncodedString(),
            nonce.base64EncodedString(),
            tag.base64EncodedString(),
            ciphertext.base64EncodedString()
        ].joined(separator: "|")
    }

    /// Deserializes a `QRE1|...` string into an `EncryptedPayloadEnvelope`.
    public static func deserialize(from text: String) throws -> EncryptedPayloadEnvelope {
        let parts = text.components(separatedBy: "|")
        guard parts.count == 5, parts[0] == magicHeader else {
            throw CryptoEnvelopeError.invalidFormat
        }
        guard let salt = Data(base64Encoded: parts[1]),
              let nonce = Data(base64Encoded: parts[2]),
              let tag = Data(base64Encoded: parts[3]),
              let ciphertext = Data(base64Encoded: parts[4]) else {
            throw CryptoEnvelopeError.invalidFormat
        }
        return try EncryptedPayloadEnvelope(salt: salt, nonce: nonce, tag: tag, ciphertext: ciphertext)
    }

    /// Packs the envelope into a compact binary representation `[4B "QRE1"][16B salt][12B nonce][16B tag][ciphertext]`.
    public func toBinary() -> Data {
        var data = Data(Self.magicHeader.utf8)
        data.append(salt)
        data.append(nonce)
        data.append(tag)
        data.append(ciphertext)
        return data
    }

    /// Unpacks a binary representation into an `EncryptedPayloadEnvelope`.
    public static func fromBinary(_ data: Data) throws -> EncryptedPayloadEnvelope {
        let headerLen = 4
        let minLen = headerLen + saltByteCount + nonceByteCount + tagByteCount
        guard data.count >= minLen else {
            throw CryptoEnvelopeError.invalidFormat
        }
        let magic = String(data: data.subdata(in: 0..<headerLen), encoding: .utf8)
        guard magic == magicHeader else {
            throw CryptoEnvelopeError.invalidFormat
        }
        let saltStart = headerLen
        let nonceStart = saltStart + saltByteCount
        let tagStart = nonceStart + nonceByteCount
        let cipherStart = tagStart + tagByteCount

        let salt = data.subdata(in: saltStart..<nonceStart)
        let nonce = data.subdata(in: nonceStart..<tagStart)
        let tag = data.subdata(in: tagStart..<cipherStart)
        let ciphertext = data.subdata(in: cipherStart..<data.count)

        return try EncryptedPayloadEnvelope(salt: salt, nonce: nonce, tag: tag, ciphertext: ciphertext)
    }

    /// Convenience helper to seal plaintext and pack it into the binary container format.
    public static func packBinary(plaintext: Data, passphrase: String, context: String = "") throws -> Data {
        let envelope = try seal(plaintext: plaintext, passphrase: passphrase, context: context)
        return envelope.toBinary()
    }

    /// Convenience helper to unpack and decrypt a binary container.
    public static func unpackBinary(packed: Data, passphrase: String, context: String = "") throws -> Data {
        let envelope = try fromBinary(packed)
        return try envelope.open(passphrase: passphrase, context: context)
    }

    private static func makeAAD(salt: Data, nonce: Data, context: String) -> Data {
        var aad = Data("\(magicHeader)|\(context)|".utf8)
        aad.append(salt)
        aad.append(nonce)
        return aad
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes)
    }
}
