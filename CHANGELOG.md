# Changelog

All notable changes to `QRDrop` are documented in this file.

## [0.2.0] - 2026-11-20

### Added
- **Protocol v2 (`QRF2`) with Per-Frame CRC32 and 64-Hex SHA-256**: Added `QRF2` frame serialization and deserialization (`TransferPacket.serializeV2()`) carrying `PacketFlags`, a full 64-character SHA-256 stream digest, and an 8-character IEEE 802.3 `CRC32` per-chunk checksum while preserving backward compatibility with `QRF1`.
- **Luby Transform (LT) Fountain Erasure Coding (`QRFF`)**: Added `FountainEncoder`, `FountainDecoder`, and `FountainDroplet` with deterministic `SplitMix64` degree/block sampling and incremental GF(2) Gauss-Jordan elimination so arbitrary out-of-order droplet subsets recover payloads under simulated frame loss.
- **Authenticated Encrypted Payload Envelope (`QRE1`)**: Added `EncryptedPayloadEnvelope` combining `HKDF<SHA256>` key derivation (16-byte random salt and domain-separated context info) with `AES.GCM` 256-bit authenticated encryption (12-byte nonce, 16-byte authentication tag, and header/context AAD binding) in both pipe-delimited string (`QRE1|...`) and compact binary container formats.
- **Structured QR Payload Encoders, Parsers, and Inspector**: Added `WiFiPayload` (`WIFI:`), `VCardPayload` (`BEGIN:VCARD` v3.0), `URIPayload` (with scheme whitelist and dangerous scheme rejection), and `QRPayloadInspector` for unified classification across `qrf1`, `qrf2`, `qrff`, `qre1`, `wifi`, `vcard`, `uri`, and `text`.
- **Hostile-Input Hardening and Out-of-Order Session Assembler**: Added `TransferSessionAssembler`, filename path-traversal and control-character sanitization (`TransferPacket.sanitizeFileName`), bounded zlib decompression (`DataCompressor.decompressBounded`), and strict chunk index/size validation.
- **SwiftPM Package, `qrdrop` CLI, and Automated Test Suite**: Added `Package.swift` exposing `QRDropCore`, the `qrdrop` command-line tool (`encode`, `decode`, `encrypt`, `decrypt`, `payload`, `benchmark`), and 13 automated XCTest suites in `Tests/QRDropTests`.

## [0.1.0] - 2026-03-01

### Added
- Initial macOS and iOS SwiftUI optical QR file and text transfer application (`QRF1` framing, zlib compression, CoreImage QR generator, and AVFoundation/Vision camera scanner).
