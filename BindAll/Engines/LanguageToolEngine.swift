import Foundation

/// Grammar and spelling correction via a LanguageTool server (the public API, a self-hosted server,
/// or LanguageTool Premium). Unlike the AI engines, this does not follow instructions: it only
/// corrects the text, so it powers the dedicated "Correct" action rather than the engine dropdown.
struct LanguageToolEngine {
    /// Base URL including the API version, e.g. `https://api.languagetool.org/v2`.
    let baseURL: String
    /// Account email (Premium only; ignored by the free/self-hosted servers).
    let username: String
    /// API token (Premium only).
    let apiKey: String
    /// BCP-47 language code, or "auto" to let the server detect it.
    let language: String

    /// Corrects `text` and returns the result with all suggested replacements applied.
    func correct(_ text: String) async throws -> String {
        let url = try endpoint("/check")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(["text": text, "language": language.isEmpty ? "auto" : language])

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.validate(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else {
            throw EngineError.emptyResponse
        }
        return Self.applyMatches(matches, to: text)
    }

    /// Lightweight connectivity check against the server's language list.
    func testConnection() async throws -> String {
        let url = try endpoint("/languages")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.validate(response: response, data: data)
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return "Connected — \(arr.count) languages"
        }
        return "Connected"
    }

    // MARK: - Match application

    /// Applies LanguageTool `matches` (first replacement of each) to `text`.
    /// Offsets and lengths are UTF-16 code units (LanguageTool uses Java char indices), so edits are
    /// done on an `NSMutableString` and applied right-to-left to keep earlier offsets valid.
    static func applyMatches(_ matches: [[String: Any]], to text: String) -> String {
        let edits: [(offset: Int, length: Int, replacement: String)] = matches.compactMap { m in
            guard let offset = m["offset"] as? Int,
                  let length = m["length"] as? Int,
                  let replacements = m["replacements"] as? [[String: Any]],
                  let value = replacements.first?["value"] as? String else { return nil }
            return (offset, length, value)
        }.sorted { $0.offset > $1.offset }

        let result = NSMutableString(string: text)
        var lastStart = result.length
        for edit in edits {
            // Skip malformed or overlapping ranges.
            guard edit.offset >= 0, edit.length >= 0,
                  edit.offset + edit.length <= result.length,
                  edit.offset + edit.length <= lastStart else { continue }
            result.replaceCharacters(in: NSRange(location: edit.offset, length: edit.length),
                                     with: edit.replacement)
            lastStart = edit.offset
        }
        return result as String
    }

    // MARK: - Helpers

    private func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw EngineError.network("Invalid LanguageTool URL: \(baseURL)")
        }
        return url
    }

    private func formBody(_ params: [String: String]) -> Data {
        var all = params
        if !username.isEmpty { all["username"] = username }
        if !apiKey.isEmpty { all["apiKey"] = apiKey }
        let encoded = all.map { key, value in
            "\(Self.formEncode(key))=\(Self.formEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw EngineError.network("HTTP \(http.statusCode): \(body.prefix(300))")
        }
    }
}
