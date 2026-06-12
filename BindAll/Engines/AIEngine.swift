import Foundation

enum EngineError: LocalizedError {
    case unavailable(String)
    case network(String)
    case emptyResponse
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .network(let message): return message
        case .emptyResponse: return "The model returned an empty response."
        case .missingAPIKey: return "No API key configured for this provider."
        }
    }
}

/// An engine that transforms text according to an instruction (e.g. "fix grammar", "translate ...").
protocol AIEngine {
    /// Runs `instruction` over `text` and returns the processed result.
    func process(text: String, instruction: String) async throws -> String

    /// Quick connectivity / availability check. Returns a short status string on success.
    func testConnection() async throws -> String
}
