import AppKit
import Vision

/// Captures a user-selected screen region and recognizes text in it with the Vision framework.
enum OCRService {
    enum OCRError: LocalizedError {
        case cancelled
        case noImage
        case noText
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Screen selection was cancelled."
            case .noImage: return "Could not capture the selected area."
            case .noText: return "No readable text was found in the selection."
            }
        }
    }

    /// Interactively asks the user to drag-select a screen region, then OCRs it.
    /// Runs the blocking capture/recognition off the main thread.
    static func captureAndRecognize() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try captureAndRecognizeSync()
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func captureAndRecognizeSync() throws -> String {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("bindall_ocr_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Interactive region capture via the system tool (no app-level Screen Recording prompt needed).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", tmp] // -i interactive, -x no sound
        try process.run()
        process.waitUntilExit()

        guard FileManager.default.fileExists(atPath: tmp),
              let image = NSImage(contentsOfFile: tmp) else {
            throw OCRError.cancelled // user pressed Esc → no file written
        }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.noImage
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OCRError.noText }
        return text
    }
}
