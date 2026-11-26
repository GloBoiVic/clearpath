import Foundation

/// The result of the privileged `restore` command, read from osascript's exit status and its
/// error text, which carries the service tool's own reason.
enum RestoreOutcome: Equatable {
    case completed, canceled
    case failed(reason: String?)

    static let nextStep = "Try again. If it still fails, use Leave Clearpath to remove Clearpath and restore DNS."

    /// osascript reports a failed `do shell script` as `…execution error: <stderr> (<status>)`.
    static func from(status: Int32, errorOutput: String) -> RestoreOutcome {
        if status == 0 { return .completed }
        let text = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = text.range(of: "execution error: "),
              let code = text.range(of: #" \((-?\d+)\)$"#, options: .regularExpression) else { return .failed(reason: nil) }
        if text[code] == " (-128)" { return .canceled }
        // The service tool exits 2 for a refusal and 1 for a failure, each with one sentence.
        guard [" (1)", " (2)"].contains(String(text[code])), marker.upperBound <= code.lowerBound else { return .failed(reason: nil) }
        let reason = String(text[marker.upperBound..<code.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 200, !reason.contains("\n") else { return .failed(reason: nil) }
        return .failed(reason: reason)
    }

    /// What the panel says after the command; nothing when it worked or the person canceled.
    var message: String? {
        switch self {
        case .completed, .canceled: return nil
        case .failed(let reason?): return "Restore internet didn’t finish. \(reason) \(Self.nextStep)"
        case .failed(nil): return "Restore internet didn’t finish. \(Self.nextStep)"
        }
    }
}
