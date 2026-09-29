import Foundation

/// One client for every OpenAI-compatible provider: DeepSeek, OpenRouter, OpenAI and Ollama.
struct OpenAICompatibleEngine: AIEngine {
    let baseURL: String
    let apiKey: String
    let model: String
    let requiresAPIKey: Bool
    /// Only for error text ("DeepSeek rejected the API key…") -- never sent on the wire. Optional so
    /// existing call sites that do not have a display name handy still compile; defaults to a generic
    /// "the provider" in messages.
    var providerName: String = ""

    private var providerLabel: String { providerName.isEmpty ? "The provider" : providerName }

    private func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw EngineError.network("Invalid base URL: \(baseURL)")
        }
        return url
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    func process(text: String, instruction: String) async throws -> String {
        if requiresAPIKey && apiKey.isEmpty { throw EngineError.missingAPIKey }

        let url = try endpoint("/chat/completions")
        var req = makeRequest(url: url, method: "POST")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text],
            ],
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw EngineError.emptyResponse
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyResponse }
        return trimmed
    }

    /// `/models` is a listing endpoint, not an auth check -- OpenRouter's answers it publicly, with
    /// any key or none at all. The only request that actually exercises the key is a real chat
    /// completion, so that is what this always does (a `:free` OpenRouter model costs nothing).
    func testConnection() async throws -> String {
        if requiresAPIKey && apiKey.isEmpty { throw EngineError.missingAPIKey }
        _ = try await process(text: "ping", instruction: "Reply with OK.")
        return "Connected"
    }

    /// Fetches available model identifiers (best effort).
    /// - Parameter freeOnly: when true, keeps only free models (id ending in ":free" or zero pricing).
    func listModels(freeOnly: Bool = false) async throws -> [String] {
        if requiresAPIKey && apiKey.isEmpty { throw EngineError.missingAPIKey }
        let url = try endpoint("/models")
        let req = makeRequest(url: url, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response: response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr
            .compactMap { $0["id"] as? String }
            .filter { !freeOnly || $0.hasSuffix(":free") }
            .sorted()
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw EngineError.network("\(providerLabel) rejected the API key (HTTP \(http.statusCode)). Check the key on the Providers tab -- it may be missing, wrong, or belong to a different provider. \(body.prefix(200))")
            }
            throw EngineError.network("HTTP \(http.statusCode): \(body.prefix(300))")
        }
    }
}
