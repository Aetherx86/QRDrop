import Foundation

/// Validation and parsing errors for structured QR payloads (Wi-Fi, vCard, URI).
public nonisolated enum StructuredPayloadError: Error, Equatable, Sendable {
    case invalidFormat
    case invalidSSID
    case invalidAuthentication
    case invalidPasswordRequirement
    case invalidFullName
    case invalidEmail
    case invalidURI
    case forbiddenURIScheme(String)
    case controlCharacterViolation
}

/// Wi-Fi network configuration payload (`WIFI:T:<auth>;S:<ssid>;P:<password>;H:<hidden>;;`).
public nonisolated struct WiFiPayload: Sendable, Equatable {
    public enum AuthenticationType: String, CaseIterable, Sendable, Equatable {
        case wpa = "WPA"
        case wep = "WEP"
        case nopass = "nopass"

        public static func parse(_ raw: String) -> AuthenticationType? {
            switch raw.uppercased() {
            case "WPA", "WPA2", "WPA3", "WPA/WPA2":
                return .wpa
            case "WEP":
                return .wep
            case "NOPASS", "NONE", "":
                return .nopass
            default:
                return nil
            }
        }
    }

    public let ssid: String
    public let password: String
    public let authentication: AuthenticationType
    public let isHidden: Bool

    public init(
        ssid: String,
        password: String = "",
        authentication: AuthenticationType = .wpa,
        isHidden: Bool = false
    ) throws {
        guard !Self.containsControlCharacters(ssid),
              !Self.containsControlCharacters(password) else {
            throw StructuredPayloadError.controlCharacterViolation
        }
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty, ssid.utf8.count <= 32 else {
            throw StructuredPayloadError.invalidSSID
        }
        switch authentication {
        case .nopass:
            guard password.isEmpty else {
                throw StructuredPayloadError.invalidPasswordRequirement
            }
        case .wpa, .wep:
            guard !password.isEmpty, password.utf8.count <= 128 else {
                throw StructuredPayloadError.invalidPasswordRequirement
            }
        }

        self.ssid = ssid
        self.password = password
        self.authentication = authentication
        self.isHidden = isHidden
    }

    public func encode() -> String {
        var fields: [String] = [
            "T:\(authentication.rawValue)",
            "S:\(Self.escape(ssid))"
        ]
        if authentication != .nopass {
            fields.append("P:\(Self.escape(password))")
        }
        if isHidden {
            fields.append("H:true")
        }
        return "WIFI:" + fields.joined(separator: ";") + ";;"
    }

    public static func parse(_ raw: String) throws -> WiFiPayload {
        guard raw.hasPrefix("WIFI:"), raw.hasSuffix(";") else {
            throw StructuredPayloadError.invalidFormat
        }
        let body = String(raw.dropFirst(5))
        let tokens = try splitEscapedFields(body)

        var auth: AuthenticationType = .nopass
        var hasAuth = false
        var ssid: String?
        var password = ""
        var isHidden = false

        for token in tokens where !token.isEmpty {
            guard let colonIndex = token.firstIndex(of: ":") else {
                throw StructuredPayloadError.invalidFormat
            }
            let key = String(token[..<colonIndex]).uppercased()
            let value = unescape(String(token[token.index(after: colonIndex)...]))

            switch key {
            case "T":
                guard let parsedAuth = AuthenticationType.parse(value) else {
                    throw StructuredPayloadError.invalidAuthentication
                }
                auth = parsedAuth
                hasAuth = true
            case "S":
                ssid = value
            case "P":
                password = value
            case "H":
                isHidden = (value.lowercased() == "true" || value == "1")
            default:
                break
            }
        }

        guard let resolvedSSID = ssid else {
            throw StructuredPayloadError.invalidSSID
        }
        if !hasAuth && !password.isEmpty {
            auth = .wpa
        }
        return try WiFiPayload(
            ssid: resolvedSSID,
            password: password,
            authentication: auth,
            isHidden: isHidden
        )
    }

    public static func escape(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count + 4)
        for ch in input {
            if ch == "\\" || ch == ";" || ch == "," || ch == ":" || ch == "\"" {
                result.append("\\")
            }
            result.append(ch)
        }
        return result
    }

    public static func unescape(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var iterator = input.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                if let escaped = iterator.next() {
                    result.append(escaped)
                } else {
                    result.append("\\")
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    private static func splitEscapedFields(_ body: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var isEscaped = false

        for ch in body {
            if isEscaped {
                current.append("\\")
                current.append(ch)
                isEscaped = false
            } else if ch == "\\" {
                isEscaped = true
            } else if ch == ";" {
                tokens.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if isEscaped {
            throw StructuredPayloadError.invalidFormat
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    fileprivate static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}

/// vCard 3.0 Contact Payload (`BEGIN:VCARD` ... `END:VCARD`).
public nonisolated struct VCardPayload: Sendable, Equatable {
    public let fullName: String
    public let organization: String?
    public let title: String?
    public let phone: String?
    public let email: String?
    public let url: String?
    public let note: String?

    public init(
        fullName: String,
        organization: String? = nil,
        title: String? = nil,
        phone: String? = nil,
        email: String? = nil,
        url: String? = nil,
        note: String? = nil
    ) throws {
        let trimmedName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !WiFiPayload.containsControlCharacters(trimmedName) else {
            throw StructuredPayloadError.invalidFullName
        }

        if let organization, WiFiPayload.containsControlCharacters(organization) {
            throw StructuredPayloadError.controlCharacterViolation
        }
        if let title, WiFiPayload.containsControlCharacters(title) {
            throw StructuredPayloadError.controlCharacterViolation
        }
        if let phone, WiFiPayload.containsControlCharacters(phone) {
            throw StructuredPayloadError.controlCharacterViolation
        }
        if let email, !email.isEmpty {
            guard !WiFiPayload.containsControlCharacters(email),
                  Self.isValidEmail(email) else {
                throw StructuredPayloadError.invalidEmail
            }
        }
        if let url, !url.isEmpty {
            _ = try URIPayload(rawValue: url)
        }

        self.fullName = trimmedName
        self.organization = organization?.isEmpty == true ? nil : organization
        self.title = title?.isEmpty == true ? nil : title
        self.phone = phone?.isEmpty == true ? nil : phone
        self.email = email?.isEmpty == true ? nil : email
        self.url = url?.isEmpty == true ? nil : url
        self.note = note?.isEmpty == true ? nil : note
    }

    public func encode() -> String {
        var lines: [String] = [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "FN:\(Self.escapeValue(fullName))"
        ]
        if let organization {
            lines.append("ORG:\(Self.escapeValue(organization))")
        }
        if let title {
            lines.append("TITLE:\(Self.escapeValue(title))")
        }
        if let phone {
            lines.append("TEL;TYPE=CELL:\(Self.escapeValue(phone))")
        }
        if let email {
            lines.append("EMAIL:\(Self.escapeValue(email))")
        }
        if let url {
            lines.append("URL:\(Self.escapeValue(url))")
        }
        if let note {
            lines.append("NOTE:\(Self.escapeValue(note))")
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\n")
    }

    public static func parse(_ raw: String) throws -> VCardPayload {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        guard lines.first?.uppercased() == "BEGIN:VCARD",
              lines.last?.uppercased() == "END:VCARD" else {
            throw StructuredPayloadError.invalidFormat
        }

        var fullName: String?
        var organization: String?
        var title: String?
        var phone: String?
        var email: String?
        var url: String?
        var note: String?

        for line in lines.dropFirst().dropLast() {
            guard let colonIndex = line.firstIndex(of: ":") else {
                throw StructuredPayloadError.invalidFormat
            }
            let rawKey = String(line[..<colonIndex]).uppercased()
            let keyName = rawKey.split(separator: ";").first.map(String.init) ?? rawKey
            let value = unescapeValue(String(line[line.index(after: colonIndex)...]))

            switch keyName {
            case "FN":
                fullName = value
            case "ORG":
                organization = value
            case "TITLE":
                title = value
            case "TEL":
                phone = value
            case "EMAIL":
                email = value
            case "URL":
                url = value
            case "NOTE":
                note = value
            default:
                break
            }
        }

        guard let resolvedName = fullName else {
            throw StructuredPayloadError.invalidFullName
        }

        return try VCardPayload(
            fullName: resolvedName,
            organization: organization,
            title: title,
            phone: phone,
            email: email,
            url: url,
            note: note
        )
    }

    public static func escapeValue(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\":
                out.append("\\\\")
            case "\n":
                out.append("\\n")
            case ";":
                out.append("\\;")
            case ",":
                out.append("\\,")
            default:
                out.append(ch)
            }
        }
        return out
    }

    public static func unescapeValue(_ value: String) -> String {
        var out = ""
        var iterator = value.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\" {
                if let next = iterator.next() {
                    if next == "n" || next == "N" {
                        out.append("\n")
                    } else {
                        out.append(next)
                    }
                } else {
                    out.append("\\")
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else {
            return false
        }
        let domainParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domainParts.count >= 2 && domainParts.allSatisfy { !$0.isEmpty }
    }
}

/// Validated URI payload with scheme whitelist and injection protection.
public nonisolated struct URIPayload: Sendable, Equatable {
    public static let allowedSchemes: Set<String> = ["https", "http", "mailto", "tel"]
    public static let forbiddenSchemes: Set<String> = ["javascript", "data", "file", "vbscript"]

    public let rawValue: String
    public let scheme: String

    public init(rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !WiFiPayload.containsControlCharacters(trimmed),
              !trimmed.contains(" ") else {
            throw StructuredPayloadError.invalidURI
        }

        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased(),
              !rawScheme.isEmpty else {
            throw StructuredPayloadError.invalidURI
        }

        if Self.forbiddenSchemes.contains(rawScheme) {
            throw StructuredPayloadError.forbiddenURIScheme(rawScheme)
        }
        guard Self.allowedSchemes.contains(rawScheme) else {
            throw StructuredPayloadError.forbiddenURIScheme(rawScheme)
        }

        if rawScheme == "http" || rawScheme == "https" {
            guard let host = components.host, !host.isEmpty else {
                throw StructuredPayloadError.invalidURI
            }
        } else if rawScheme == "mailto" || rawScheme == "tel" {
            guard !components.path.isEmpty else {
                throw StructuredPayloadError.invalidURI
            }
        }

        self.rawValue = trimmed
        self.scheme = rawScheme
    }
}

/// Classification result produced by `QRPayloadInspector`.
public nonisolated enum QRPayloadKind: Sendable, Equatable {
    case qrf1Packet(TransferPacket)
    case qrf2Packet(TransferPacket)
    case fountainDroplet(FountainDroplet)
    case encryptedEnvelope(EncryptedPayloadEnvelope)
    case wifi(WiFiPayload)
    case vcard(VCardPayload)
    case uri(URIPayload)
    case plainText(String)

    public var typeIdentifier: String {
        switch self {
        case .qrf1Packet: return "qrf1"
        case .qrf2Packet: return "qrf2"
        case .fountainDroplet: return "qrff"
        case .encryptedEnvelope: return "qre1"
        case .wifi: return "wifi"
        case .vcard: return "vcard"
        case .uri: return "uri"
        case .plainText: return "text"
        }
    }
}

/// Unified inspector that classifies and validates raw QR payload strings.
public nonisolated enum QRPayloadInspector {
    public static func inspect(_ raw: String) -> QRPayloadKind {
        if raw.hasPrefix(TransferPacket.magicHeader + "|"),
           let packet = TransferPacket.deserialize(from: raw) {
            return .qrf1Packet(packet)
        }
        if raw.hasPrefix(TransferPacket.magicHeaderV2 + "|"),
           let packet = TransferPacket.deserialize(from: raw) {
            return .qrf2Packet(packet)
        }
        if raw.hasPrefix(FountainDroplet.magicHeader + "|"),
           let droplet = FountainDroplet.deserialize(from: raw) {
            return .fountainDroplet(droplet)
        }
        if raw.hasPrefix(EncryptedPayloadEnvelope.magicHeader + "|"),
           let envelope = try? EncryptedPayloadEnvelope.deserialize(from: raw) {
            return .encryptedEnvelope(envelope)
        }
        if raw.hasPrefix("WIFI:"),
           let wifi = try? WiFiPayload.parse(raw) {
            return .wifi(wifi)
        }
        if raw.uppercased().hasPrefix("BEGIN:VCARD"),
           let vcard = try? VCardPayload.parse(raw) {
            return .vcard(vcard)
        }
        if let uri = try? URIPayload(rawValue: raw) {
            return .uri(uri)
        }
        return .plainText(raw)
    }
}
