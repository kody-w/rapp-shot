import Foundation

public struct CredentialHit: Equatable, Sendable {
    public let text: String
    public let label: String
}

private struct Expression: @unchecked Sendable {
    let regex: NSRegularExpression
    init(_ pattern: String) {
        // These are audited, constant rules from detect.py; custom rules use a throwing initializer.
        regex = try! NSRegularExpression(pattern: pattern)
    }
    init(validating pattern: String) throws { regex = try NSRegularExpression(pattern: pattern) }
    func values(_ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    func has(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public struct CredentialDetector: Sendable {
    private var custom: [Expression] = []
    private static let homoglyphs: [Character: String] = [
        "А":"A", "В":"B", "Е":"E", "К":"K", "М":"M", "Н":"H", "О":"O",
        "Р":"P", "С":"C", "Т":"T", "У":"Y", "Х":"X", "З":"3", "б":"6",
        "а":"a", "е":"e", "о":"o", "р":"p", "с":"c", "х":"x", "у":"y",
        "І":"I", "і":"i", "Ј":"J", "ј":"j", "Ѕ":"S", "ѕ":"s",
        "Α":"A", "Β":"B", "Ε":"E", "Ζ":"Z", "Η":"H", "Ι":"I", "Κ":"K",
        "Μ":"M", "Ν":"N", "Ο":"O", "Ρ":"P", "Τ":"T", "Υ":"Y", "Χ":"X",
        "ο":"o", "ν":"v", "×":"x", "Ø":"0", "‚":",", "’":"'", "‘":"'",
        "“":"\"", "”":"\"", "–":"-", "—":"-", "−":"-", "|":"l", "¦":"l",
        "０":"0", "１":"1", "２":"2", "３":"3", "４":"4", "５":"5",
        "６":"6", "７":"7", "８":"8", "９":"9"
    ]
    private static let patterns: [(Expression, String)] = [
        (#"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, "email"),
        (#"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#, "github token"),
        (#"\bsk-[A-Za-z0-9-]{20,}\b"#, "openai-style key"),
        (#"(?i)\b(sk|pk|rk)_(live|test)_[A-Za-z0-9]{10,}\b"#, "stripe-style key"),
        (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "slack token"),
        (#"(?i)\b(SG|AC|SK)[0-9a-f]{20,}\b"#, "vendor id/secret"),
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, "private key block"),
        (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s:/@]+:[^\s:/@]{4,}@[^\s/]+"#, "credentials in a connection URL"),
        (#"(?i)[?&](access_token|api_key|apikey|token|key|password|sig|signature)=[A-Za-z0-9._~+/%-]{8,}"#, "token in a URL"),
        (#"(?i)(?<![A-Za-z])(api[\s_.-]?key|secret|password|passwd|token|bearer|credential|auth[\s_.-]?token|access[\s_.-]?key|key)(?![A-Za-z])\s*[:=]\s*["']?([A-Za-z0-9._~+/=-]{12,})"#, "labelled credential value"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "aws access key"),
        (#"\bey[JA-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."#, "jwt"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{16,}"#, "bearer token"),
        (#"(?i)\b(api[_-]?key|secret|password|passwd|token)\b\s*[:=]\s*\S{6,}"#, "labelled secret"),
        (#"\b(?:\d[ -]*?){13,16}\b"#, "card-like number"),
        (#"\b\d{3}-\d{2}-\d{4}\b"#, "ssn-like")
    ].map { (Expression($0.0), $0.1) }
    private static let label = Expression(#"(?i)(?:(?<![A-Za-z])|(?<=[a-z0-9]))(api[\s_.-]?key|secret|password|passwd|passphrase|token|bearer|credential|auth|key|private[\s_.-]?key|access[\s_.-]?key|client[\s_.-]?secret|conn(ection)?[\s_.-]?str(ing)?)(?:(?![A-Za-z])|(?=[A-Z]))"#)
    private static let uuid = Expression(#"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#)
    private static let hex = Expression(#"(?i)^[0-9a-f]{24,}$"#)
    private static let benignPrefix = Expression(#"(?i)^(https?://|/|~|\.{1,2}/|[a-z]+\.(com|org|net|io|dev|ai)$)"#)
    private static let path = Expression(#"^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)+/?$"#)
    private static let dns = Expression(#"^[a-z]{2,}(\.[A-Za-z0-9-]{2,}){2,}$"#)
    private static let timestamp = Expression(#"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?([.,]\d+)?(Z|[+-]\d{2}:?\d{2})?)?$"#)
    private static let ipv6 = Expression(#"(?i)^(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(%[A-Za-z0-9]+)?(/\d{1,3})?$"#)
    private static let pieces = Expression(#"[^/._\-=:?&@+~,;|\\]+"#)
    private static let words = Expression(#"[A-Z][a-z]*|[a-z]+"#)
    private static let runs = Expression(#"[^\s'"`,;()\[\]{}<>]{12,}"#)

    public init(patternText: String = "") throws {
        for (offset, raw) in patternText.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard line.utf8.count <= 4_096, custom.count < 256 else {
                throw ShotError.invalidPattern(offset + 1, "Limit: 256 patterns, 4096 bytes per pattern.")
            }
            do { custom.append(try Expression(validating: line)) }
            catch { throw ShotError.invalidPattern(offset + 1, error.localizedDescription) }
        }
    }

    public static func load(from file: URL) throws -> CredentialDetector {
        guard FileManager.default.fileExists(atPath: file.path) else { return try CredentialDetector() }
        do { return try CredentialDetector(patternText: String(contentsOf: file, encoding: .utf8)) }
        catch let error as ShotError { throw error }
        catch { throw ShotError.unreadablePatterns(error.localizedDescription) }
    }

    public static func normalize(_ text: String) -> String {
        let mapped = text.map { homoglyphs[$0] ?? String($0) }.joined()
        return String(String.UnicodeScalarView(
            mapped.decomposedStringWithCompatibilityMapping.unicodeScalars.filter {
                !CharacterSet.nonBaseCharacters.contains($0)
            }
        ))
    }

    public static func entropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let counts = Dictionary(text.map { ($0, 1) }, uniquingKeysWith: +)
        return -counts.values.reduce(0) {
            let p = Double($1) / Double(text.count)
            return $0 + p * log2(p)
        }
    }

    private static func classes(_ text: String) -> Int {
        [text.contains(where: \.isLowercase), text.contains(where: \.isUppercase),
         text.contains(where: \.isNumber), text.contains { !$0.isLetter && !$0.isNumber }]
            .filter { $0 }.count
    }

    private static func wordlike(_ text: String) -> Bool {
        guard text.allSatisfy(\.isLetter), text.count <= 30 else { return false }
        if text == text.lowercased() || text == text.uppercased() ||
            (text.first?.isUppercase == true && text.dropFirst().allSatisfy(\.isLowercase)) {
            return text.count >= 2
        }
        let parts = words.values(text)
        return parts.count >= 2 && parts.allSatisfy { $0.count >= 2 }
    }

    private static func opaque(_ segment: String, floor: Int = 20) -> Bool {
        guard segment.count >= floor, !uuid.has(segment), !wordlike(segment),
              !segment.allSatisfy(\.isNumber) else { return false }
        return hex.has(segment) || (entropy(segment) >= 3.4 && classes(segment) >= 2)
    }

    private static func joinedOpaque(_ core: String, floor: Int) -> Bool {
        let segments = pieces.values(core)
        guard segments.count >= 2 else { return false }
        let total = segments.reduce(0) { $0 + $1.count }
        let wordCharacters = segments.filter(wordlike).reduce(0) { $0 + $1.count }
        guard Double(wordCharacters) / Double(max(1, total)) < 0.30 else { return false }
        let joined = segments.joined()
        guard joined.count >= floor else { return false }
        if hex.has(joined) { return joined.count >= 32 }
        return entropy(joined) >= 3.4 && classes(joined) >= 2
    }

    private static func uniformGroups(_ core: String) -> Bool {
        let segments = pieces.values(core)
        guard segments.count >= 3, let length = segments.first?.count,
              (4...8).contains(length), segments.allSatisfy({ $0.count == length }),
              segments.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }),
              core.contains(where: \.isNumber) else { return false }
        return entropy(segments.joined()) >= 3.4
    }

    private static func hiddenSecret(_ core: String) -> String? {
        if let segment = pieces.values(core).first(where: { opaque($0) }) { return segment }
        return joinedOpaque(core, floor: 24) || uniformGroups(core) ? core : nil
    }

    private static func structured(_ core: String) -> Bool {
        benignPrefix.has(core) || path.has(core) || dns.has(core)
    }

    private static func benign(_ core: String) -> Bool {
        if uuid.has(core) || timestamp.has(core) || ipv6.has(core) { return true }
        return structured(core) && hiddenSecret(core) == nil
    }

    private static func shapeHits(_ text: String) -> [CredentialHit] {
        var hits: [CredentialHit] = []
        let labelled = label.has(text)
        for run in runs.values(text) {
            let core = run.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;="))
            guard core.count >= 12, !benign(core) else { continue }
            if structured(core), let hidden = hiddenSecret(core) {
                hits.append(CredentialHit(text: hidden, label: "credential inside a path"))
                continue
            }
            let before = text.range(of: run).map { String(text[..<$0.lowerBound]) } ?? ""
            let afterLabel = labelled && label.has(before)
            if hex.has(core), core.count >= (afterLabel ? 24 : 32) {
                hits.append(CredentialHit(text: core, label: afterLabel ? "hex credential" : "long hex run"))
                continue
            }
            let floor = afterLabel ? 14 : 20
            let segments = pieces.values(core)
            let bySegment = segments.contains { opaque($0, floor: floor) }
            let byJoined = joinedOpaque(core, floor: floor)
            let byGroups = uniformGroups(core)
            guard bySegment || byJoined || byGroups else { continue }
            let longEnough = core.count >= (afterLabel ? 14 : 20) || (byGroups && core.count >= 15)
            let longOpaque = segments.contains { $0.count >= 32 && opaque($0) }
            let classFloor = afterLabel || longOpaque ? 2 : 3
            if longEnough, classes(core) >= classFloor, entropy(core) >= (afterLabel ? 2.6 : 3.0) {
                hits.append(CredentialHit(text: core, label: afterLabel ? "labelled high-entropy run" : "high-entropy run"))
            }
        }
        return hits
    }

    public func find(_ text: String) -> [CredentialHit] {
        let normalized = Self.normalize(text)
        var found: [CredentialHit] = []
        for (rule, label) in Self.patterns {
            found += rule.values(normalized).map { CredentialHit(text: $0, label: label) }
        }
        for rule in custom {
            found += rule.values(normalized).map { CredentialHit(text: $0, label: "custom") }
        }
        for hit in Self.shapeHits(normalized) where !found.contains(where: { $0.text.contains(hit.text) }) {
            found.append(hit)
        }
        return found
    }

    public static func stillPresent(_ needle: String, in haystack: String) -> Bool {
        let n = normalize(needle).filter { !$0.isWhitespace }
        let h = normalize(haystack).filter { !$0.isWhitespace }
        guard !n.isEmpty else { return false }
        let probe = n.count < 8 ? n : String(n.prefix(max(12, n.count / 2)))
        return h.contains(probe)
    }
}
