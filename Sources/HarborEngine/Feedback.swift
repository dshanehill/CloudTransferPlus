import AppKit
import AVFoundation

/// Sound and spoken progress (0.7). The app uses SystemFeedback; tests use SilentFeedback.
@MainActor public protocol FeedbackOutput {
    func chime(_ kind: ChimeKind)
    /// Quiet "still working" tick, like a screen-reader installer's progress clicking.
    func tick()
    func say(_ text: String)
    func stopSpeaking()
}

public enum ChimeKind { case started, progress, paused, stopped, finished, problem }

@MainActor public final class SystemFeedback: FeedbackOutput {
    private let speech = AVSpeechSynthesizer()
    public init() {}
    public func chime(_ kind: ChimeKind) {
        let name: String
        switch kind {
        case .started: name = "Hero"
        case .progress: name = "Glass"
        case .paused: name = "Pop"
        case .stopped: name = "Bottle"
        case .finished: name = "Funk"
        case .problem: name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
    public func tick() {
        guard !speech.isSpeaking, let sound = NSSound(named: NSSound.Name("Tink"))?.copy() as? NSSound else { return }
        sound.volume = 0.18; sound.play()
    }
    public func say(_ text: String) {
        // Newest announcement wins; never queue a backlog of stale percentages.
        if speech.isSpeaking { speech.stopSpeaking(at: .word) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.preUtteranceDelay = 0.35 // let the chime finish first
        speech.speak(utterance)
    }
    public func stopSpeaking() { speech.stopSpeaking(at: .immediate) }
}

@MainActor public final class SilentFeedback: FeedbackOutput {
    public private(set) var chimes: [ChimeKind] = []
    public private(set) var spoken: [String] = []
    public init() {}
    public func chime(_ kind: ChimeKind) { chimes.append(kind) }
    public private(set) var ticks = 0
    public func tick() { ticks += 1 }
    public func say(_ text: String) { spoken.append(text) }
    public func stopSpeaking() {}
}

public enum ParallelPolicy: Sendable {
    case fixed(Int)
    /// `active` files at a time while the Mac is in use; `idle` after `idleAfter` seconds without keyboard or mouse input.
    case adaptive(active: Int, idle: Int, idleAfter: TimeInterval)
}

public struct ActiveFile: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var bytes: Int64
    public var done: Int64
    public var phase: String
    public var started: Date
}

public struct BatchInfo: Sendable {
    public let number: Int, count: Int, firstFile: Int, lastFile: Int
    public let files: Int, settledFiles: Int
    public let bytes: Int64, settledBytes: Int64
    public let remainingFiles: Int, remainingBytes: Int64
    public var reviewFiles: Int = 0
}

public enum ProgressTiming {
    /// Fits seconds ≈ overhead + bytes × secondsPerByte over finished files, then divides by the measured average number
    /// of files running side by side (total file-seconds ÷ wall-clock seconds).
    public static func estimate(samples: [(bytes: Int64, seconds: Double)], sumFileSeconds: Double, wallSeconds: Double, files: Int, bytes: Int64) -> Double? {
        guard samples.count >= 3, wallSeconds > 0 else { return nil }
        let n = Double(samples.count)
        let xs = samples.map { Double($0.bytes) }, ys = samples.map { $0.seconds }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in xs.indices { sxy += (xs[i] - mx) * (ys[i] - my); sxx += (xs[i] - mx) * (xs[i] - mx) }
        var perByte = sxx > 0 ? max(0, sxy / sxx) : 0
        var overhead = my - perByte * mx
        if overhead < 0 { overhead = 0; perByte = ys.reduce(0, +) / max(xs.reduce(0, +), 1) }
        let parallel = max(1, sumFileSeconds / wallSeconds)
        let work = Double(files) * overhead + Double(bytes) * perByte
        return work > 0 ? work / parallel : nil
    }
    public static func format(seconds: Double, spoken: Bool) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]; f.maximumUnitCount = 2
        f.unitsStyle = spoken ? .full : .abbreviated
        return f.string(from: max(60, seconds.rounded())) ?? "unknown"
    }
    /// Bytes per second from the work done while transferring (pauses excluded). Nil until there is enough evidence.
    public static func rate(bytes: Int64, seconds: TimeInterval, files: Int) -> Double? {
        guard bytes > 0, seconds >= 30, files >= 2 else { return nil }
        return Double(bytes) / seconds
    }
    /// "2 days, 4 hours" (spoken) or "2d 4h" (short). Rounded to two units; never claims seconds-level precision.
    public static func remaining(bytes: Int64, rate: Double, spoken: Bool) -> String {
        let seconds = max(60, (Double(bytes) / max(rate, 1)).rounded())
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]; f.maximumUnitCount = 2
        f.unitsStyle = spoken ? .full : .abbreviated
        return f.string(from: seconds) ?? "unknown"
    }
}
