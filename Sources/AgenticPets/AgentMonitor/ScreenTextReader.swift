import AppKit
import Vision

/// Best-effort OCR of the current screen contents, so we can tell what a coding
/// agent is doing regardless of which tool/terminal it's running in — reading
/// pixels instead of trying to parse each tool's own log format.
enum ScreenTextReader {
    /// Returns nil if Screen Recording permission hasn't been granted, or nothing
    /// could be read. Requires the user to grant Screen Recording access to this
    /// app in System Settings > Privacy & Security the first time it's called.
    static func captureScreenText() -> String? {
        guard let screen = NSScreen.main else { return nil }
        let rect = CGRect(origin: .zero, size: screen.frame.size)
        guard let cgImage = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else {
            return nil
        }

        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
