import Foundation
import QRDropCore

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

enum QRDropCLI {
    static func run(arguments: [String]) throws {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        switch command {
        case "--version", "-v", "version":
            print("qrdrop \(QRDropVersion.current)")
        case "--help", "-h", "help":
            printUsage()
        case "encode":
            try runEncode(args: Array(args.dropFirst()))
        case "decode":
            try runDecode(args: Array(args.dropFirst()))
        case "encrypt":
            try runEncrypt(args: Array(args.dropFirst()))
        case "decrypt":
            try runDecrypt(args: Array(args.dropFirst()))
        case "payload":
            try runPayload(args: Array(args.dropFirst()))
        case "benchmark":
            try runBenchmark(args: Array(args.dropFirst()))
        default:
            throw CLIError("Unknown subcommand: \(command)")
        }
    }

    private static func printUsage() {
        let text = """
        qrdrop \(QRDropVersion.current) - Offline optical QR payload protocol, fountain coder, and envelope tool

        USAGE:
          qrdrop --version
          qrdrop encode --text <str> | --input <file> [--name <filename>] [--chunk-size <bytes>] [--v1 | --v2 | --fountain] [--droplets <n>] [--passphrase <secret>] [--json]
          qrdrop decode [--input <frames-file>] [--output <file>] [--passphrase <secret>] [--json]
          qrdrop encrypt --text <str> --passphrase <secret> [--context <ctx>] [--json]
          qrdrop decrypt --envelope <qre1> --passphrase <secret> [--context <ctx>] [--json]
          qrdrop payload wifi --ssid <ssid> [--password <pw>] [--auth <WPA|WEP|nopass>] [--hidden] [--json]
          qrdrop payload vcard --name <fn> [--org <org>] [--title <title>] [--phone <tel>] [--email <mail>] [--url <url>] [--json]
          qrdrop payload inspect --raw <qr-string> [--json]
          qrdrop benchmark [--bytes <size>] [--chunk-size <bytes>] [--loss <ratio>] [--json]
        """
        print(text)
    }

    private static func runEncode(args: [String]) throws {
        var inputPath: String?
        var textInput: String?
        var fileName = "payload.bin"
        var chunkSize = 450
        var protocolVersion = 2
        var useFountain = false
        var dropletCount: Int?
        var passphrase: String?
        var fileID = "f00d01"
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--input":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --input") }
                inputPath = args[i]
            case "--text":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --text") }
                textInput = args[i]
            case "--name":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --name") }
                fileName = args[i]
            case "--chunk-size":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 16 else {
                    throw CLIError("Invalid --chunk-size")
                }
                chunkSize = v
            case "--file-id":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --file-id") }
                fileID = args[i]
            case "--v1":
                protocolVersion = 1
                useFountain = false
            case "--v2":
                protocolVersion = 2
                useFountain = false
            case "--fountain":
                useFountain = true
            case "--droplets":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 1 else {
                    throw CLIError("Invalid --droplets")
                }
                dropletCount = v
            case "--passphrase":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --passphrase") }
                passphrase = args[i]
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("Unknown option for encode: \(args[i])")
            }
            i += 1
        }

        let rawData: Data
        if let inputPath {
            let url = URL(fileURLWithPath: inputPath)
            rawData = try Data(contentsOf: url)
            if fileName == "payload.bin" {
                fileName = url.lastPathComponent
            }
        } else if let textInput {
            rawData = Data(textInput.utf8)
            if fileName == "payload.bin" {
                fileName = "message.txt"
            }
        } else {
            throw CLIError("Either --input <file> or --text <str> is required")
        }

        if useFountain {
            let encoder = try FountainEncoder(
                fileName: fileName,
                rawFileData: rawData,
                fileID: fileID,
                blockSize: chunkSize,
                passphrase: passphrase
            )
            let count = dropletCount ?? max(encoder.sourceBlocks + 4, Int(ceil(Double(encoder.sourceBlocks) * 1.4)))
            let droplets = encoder.makeDroplets(count: count)
            let serialized = droplets.map { $0.serialize() }

            if jsonOutput {
                let dict: [String: Any] = [
                    "mode": "QRFF",
                    "fileID": encoder.fileID,
                    "fileName": encoder.fileName,
                    "originalSize": encoder.originalSize,
                    "streamLength": encoder.streamLength,
                    "sourceBlocks": encoder.sourceBlocks,
                    "dropletCount": serialized.count,
                    "sha256": encoder.sha256Hex,
                    "encrypted": encoder.flags.contains(.encryptedAESGCM),
                    "frames": serialized
                ]
                try printJSON(dict)
            } else {
                for frame in serialized {
                    print(frame)
                }
            }
        } else {
            let packets = try TransferSessionAssembler.encodePackets(
                fileName: fileName,
                data: rawData,
                fileID: fileID,
                chunkSize: chunkSize,
                protocolVersion: protocolVersion,
                passphrase: passphrase
            )
            let serialized = packets.map { $0.serialize() }

            if jsonOutput {
                let dict: [String: Any] = [
                    "mode": protocolVersion == 2 ? "QRF2" : "QRF1",
                    "fileID": packets.first?.fileID ?? fileID,
                    "fileName": packets.first?.fileName ?? fileName,
                    "originalSize": rawData.count,
                    "totalChunks": packets.count,
                    "sha256": packets.first?.sha256Prefix ?? "",
                    "encrypted": packets.first?.flags.contains(.encryptedAESGCM) ?? false,
                    "frames": serialized
                ]
                try printJSON(dict)
            } else {
                for frame in serialized {
                    print(frame)
                }
            }
        }
    }

    private static func runDecode(args: [String]) throws {
        var inputPath: String?
        var outputPath: String?
        var passphrase: String?
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--input":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --input") }
                inputPath = args[i]
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --output") }
                outputPath = args[i]
            case "--passphrase":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --passphrase") }
                passphrase = args[i]
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("Unknown option for decode: \(args[i])")
            }
            i += 1
        }

        let content: String
        if let inputPath {
            content = try String(contentsOfFile: inputPath, encoding: .utf8)
        } else {
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            content = String(data: stdinData, encoding: .utf8) ?? ""
        }

        let frames = content
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !frames.isEmpty else {
            throw CLIError("No frames provided to decode")
        }

        var assembler = TransferSessionAssembler()
        var completedFile: TransferredFileInfo?
        var acceptedFrames = 0

        for frame in frames {
            let result = try assembler.ingest(frameText: frame, passphrase: passphrase)
            switch result {
            case .duplicate:
                break
            case .accepted:
                acceptedFrames += 1
            case .completed(let fileInfo):
                acceptedFrames += 1
                completedFile = fileInfo
            }
            if completedFile != nil {
                break
            }
        }

        guard let file = completedFile else {
            throw CLIError("Incomplete session: \(assembler.receivedCount)/\(assembler.totalChunks) chunks collected")
        }

        if let outputPath {
            try file.data.write(to: URL(fileURLWithPath: outputPath))
        }

        if jsonOutput {
            let textPreview = String(data: file.data, encoding: .utf8)
            var dict: [String: Any] = [
                "fileID": file.id,
                "fileName": file.name,
                "size": file.size,
                "sha256": DataCompressor.sha256Hex(for: file.data),
                "acceptedFrames": acceptedFrames
            ]
            if let textPreview {
                dict["text"] = textPreview
            }
            try printJSON(dict)
        } else if outputPath == nil {
            if let text = String(data: file.data, encoding: .utf8) {
                print(text)
            } else {
                print(file.data.base64EncodedString())
            }
        }
    }

    private static func runEncrypt(args: [String]) throws {
        var textInput: String?
        var passphrase: String?
        var context = ""
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--text":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --text") }
                textInput = args[i]
            case "--passphrase":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --passphrase") }
                passphrase = args[i]
            case "--context":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --context") }
                context = args[i]
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("Unknown option for encrypt: \(args[i])")
            }
            i += 1
        }

        guard let textInput, let passphrase else {
            throw CLIError("Both --text and --passphrase are required")
        }

        let envelope = try EncryptedPayloadEnvelope.seal(
            plaintext: Data(textInput.utf8),
            passphrase: passphrase,
            context: context
        )
        let serialized = envelope.serialize()

        if jsonOutput {
            try printJSON([
                "format": EncryptedPayloadEnvelope.magicHeader,
                "context": context,
                "ciphertextBytes": envelope.ciphertext.count,
                "envelope": serialized
            ])
        } else {
            print(serialized)
        }
    }

    private static func runDecrypt(args: [String]) throws {
        var rawEnvelope: String?
        var passphrase: String?
        var context = ""
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--envelope":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --envelope") }
                rawEnvelope = args[i]
            case "--passphrase":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --passphrase") }
                passphrase = args[i]
            case "--context":
                i += 1
                guard i < args.count else { throw CLIError("Missing value for --context") }
                context = args[i]
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("Unknown option for decrypt: \(args[i])")
            }
            i += 1
        }

        guard let rawEnvelope, let passphrase else {
            throw CLIError("Both --envelope and --passphrase are required")
        }

        let envelope = try EncryptedPayloadEnvelope.deserialize(from: rawEnvelope)
        let plaintext = try envelope.open(passphrase: passphrase, context: context)
        let text = String(data: plaintext, encoding: .utf8) ?? plaintext.base64EncodedString()

        if jsonOutput {
            try printJSON([
                "format": EncryptedPayloadEnvelope.magicHeader,
                "plaintextBytes": plaintext.count,
                "text": text
            ])
        } else {
            print(text)
        }
    }

    private static func runPayload(args: [String]) throws {
        guard let sub = args.first else {
            throw CLIError("Missing payload subcommand (wifi, vcard, inspect)")
        }
        let rest = Array(args.dropFirst())

        switch sub {
        case "wifi":
            var ssid: String?
            var password = ""
            var auth: WiFiPayload.AuthenticationType = .wpa
            var hidden = false
            var jsonOutput = false

            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--ssid":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --ssid") }
                    ssid = rest[i]
                case "--password":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --password") }
                    password = rest[i]
                case "--auth":
                    i += 1
                    guard i < rest.count, let parsed = WiFiPayload.AuthenticationType.parse(rest[i]) else {
                        throw CLIError("Invalid --auth")
                    }
                    auth = parsed
                case "--hidden":
                    hidden = true
                case "--json":
                    jsonOutput = true
                default:
                    throw CLIError("Unknown option for payload wifi: \(rest[i])")
                }
                i += 1
            }

            guard let ssid else { throw CLIError("--ssid is required") }
            let wifi = try WiFiPayload(ssid: ssid, password: password, authentication: auth, isHidden: hidden)
            let encoded = wifi.encode()
            if jsonOutput {
                try printJSON([
                    "type": "wifi",
                    "ssid": wifi.ssid,
                    "authentication": wifi.authentication.rawValue,
                    "hidden": wifi.isHidden,
                    "payload": encoded
                ])
            } else {
                print(encoded)
            }

        case "vcard":
            var name: String?
            var org: String?
            var title: String?
            var phone: String?
            var email: String?
            var url: String?
            var note: String?
            var jsonOutput = false

            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--name":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --name") }
                    name = rest[i]
                case "--org":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --org") }
                    org = rest[i]
                case "--title":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --title") }
                    title = rest[i]
                case "--phone":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --phone") }
                    phone = rest[i]
                case "--email":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --email") }
                    email = rest[i]
                case "--url":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --url") }
                    url = rest[i]
                case "--note":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --note") }
                    note = rest[i]
                case "--json":
                    jsonOutput = true
                default:
                    throw CLIError("Unknown option for payload vcard: \(rest[i])")
                }
                i += 1
            }

            guard let name else { throw CLIError("--name is required") }
            let card = try VCardPayload(
                fullName: name,
                organization: org,
                title: title,
                phone: phone,
                email: email,
                url: url,
                note: note
            )
            let encoded = card.encode()
            if jsonOutput {
                try printJSON([
                    "type": "vcard",
                    "fullName": card.fullName,
                    "email": card.email ?? "",
                    "phone": card.phone ?? "",
                    "payload": encoded
                ])
            } else {
                print(encoded)
            }

        case "inspect":
            var raw: String?
            var jsonOutput = false

            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--raw":
                    i += 1
                    guard i < rest.count else { throw CLIError("Missing --raw") }
                    raw = rest[i]
                case "--json":
                    jsonOutput = true
                default:
                    throw CLIError("Unknown option for payload inspect: \(rest[i])")
                }
                i += 1
            }

            guard let raw else { throw CLIError("--raw is required") }
            let kind = QRPayloadInspector.inspect(raw)
            if jsonOutput {
                try printJSON([
                    "type": kind.typeIdentifier,
                    "length": raw.utf8.count
                ])
            } else {
                print("type=\(kind.typeIdentifier) bytes=\(raw.utf8.count)")
            }

        default:
            throw CLIError("Unknown payload subcommand: \(sub)")
        }
    }

    private static func runBenchmark(args: [String]) throws {
        var byteSize = 32_768
        var chunkSize = 450
        var lossRatio = 0.25
        var jsonOutput = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--bytes":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 64 else {
                    throw CLIError("Invalid --bytes")
                }
                byteSize = v
            case "--chunk-size":
                i += 1
                guard i < args.count, let v = Int(args[i]), v >= 32 else {
                    throw CLIError("Invalid --chunk-size")
                }
                chunkSize = v
            case "--loss":
                i += 1
                guard i < args.count, let v = Double(args[i]), v >= 0.0, v < 0.8 else {
                    throw CLIError("Invalid --loss (must be in 0.0..<0.8)")
                }
                lossRatio = v
            case "--json":
                jsonOutput = true
            default:
                throw CLIError("Unknown option for benchmark: \(args[i])")
            }
            i += 1
        }

        // Generate deterministic corpus combining structured text and high-entropy data
        var corpus = Data()
        corpus.reserveCapacity(byteSize)
        var rng = SplitMix64(seed: 0x2026_1120_0002_0000)
        while corpus.count < byteSize {
            let line = "QRDrop-v0.2.0-block-\(corpus.count)-token-\(String(format: "%016llx", rng.next()))\n"
            corpus.append(Data(line.utf8))
        }
        corpus = corpus.prefix(byteSize)

        let startTime = Date()
        let encoder = try FountainEncoder(
            fileName: "benchmark.dat",
            rawFileData: corpus,
            fileID: "bench1",
            blockSize: chunkSize,
            passphrase: "bench-secret-passphrase"
        )
        let generatedDropletCount = max(encoder.sourceBlocks * 3, encoder.sourceBlocks + 24)
        let droplets = encoder.makeDroplets(count: generatedDropletCount)

        // Deterministically simulate frame drops and out-of-order arrival
        var surviving: [FountainDroplet] = []
        let threshold = UInt64(lossRatio * 10_000.0)
        for droplet in droplets {
            if (rng.next() % 10_000) >= threshold {
                surviving.append(droplet)
            }
        }

        var assembler = TransferSessionAssembler()
        var dropletsUsed = 0
        var recovered = false

        for droplet in surviving {
            dropletsUsed += 1
            let res = try assembler.ingestFountainDroplet(
                droplet,
                passphrase: "bench-secret-passphrase"
            )
            if case .completed(let fileInfo) = res {
                recovered = (fileInfo.data == corpus)
                break
            }
        }
        let elapsedMs = Date().timeIntervalSince(startTime) * 1000.0

        let report: [String: Any] = [
            "version": QRDropVersion.current,
            "inputBytes": corpus.count,
            "framedStreamBytes": encoder.streamLength,
            "sourceBlocks": encoder.sourceBlocks,
            "simulatedLossRatio": lossRatio,
            "dropletsUsed": dropletsUsed,
            "overheadBlocks": max(0, dropletsUsed - encoder.sourceBlocks),
            "recovered": recovered,
            "elapsedMs": Double( round(elapsedMs * 100) / 100 )
        ]

        if jsonOutput {
            try printJSON(report)
        } else {
            print("QRDrop Benchmark (\(QRDropVersion.current)): input=\(corpus.count)B stream=\(encoder.streamLength)B K=\(encoder.sourceBlocks) loss=\(Int(lossRatio * 100))% dropletsUsed=\(dropletsUsed) recovered=\(recovered) time=\(String(format: "%.2f", elapsedMs))ms")
        }
    }

    private static func printJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}

do {
    try QRDropCLI.run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
