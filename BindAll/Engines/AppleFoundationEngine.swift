import Foundation
import FoundationModels

/// On-device engine backed by Apple Intelligence (FoundationModels framework).
struct AppleFoundationEngine: AIEngine {

    /// A human-readable availability status for the Apple on-device model.
    static func availabilityStatus() -> (available: Bool, message: String) {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return (true, "Available")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return (false, "This Mac does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return (false, "Apple Intelligence is not enabled in System Settings.")
            case .modelNotReady:
                return (false, "The model is downloading or not ready yet.")
            @unknown default:
                return (false, "Apple on-device model is unavailable.")
            }
        @unknown default:
            return (false, "Apple on-device model is unavailable.")
        }
    }

    func process(text: String, instruction: String) async throws -> String {
        let status = Self.availabilityStatus()
        guard status.available else { throw EngineError.unavailable(status.message) }

        let session = LanguageModelSession(instructions: instruction)
        let prompt = text
        do {
            // temperature 0 → deterministic, faithful edits (avoids the model "creatively" rewriting
            // or translating when it should only correct).
            let options = GenerationOptions(temperature: 0.0)
            let response = try await session.respond(to: prompt, options: options)
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw EngineError.emptyResponse }
            return content
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unavailable(error.localizedDescription)
        }
    }

    func testConnection() async throws -> String {
        let status = Self.availabilityStatus()
        guard status.available else { throw EngineError.unavailable(status.message) }
        let session = LanguageModelSession(instructions: "You are a helpful assistant.")
        let response = try await session.respond(to: "Reply with the single word: OK")
        return response.content.isEmpty ? "Connected" : "Connected"
    }
}
