import Foundation

/// Claude starts a 5-hour session window at the first request inside it, not at the moment the
/// previous window expires. While a fresh window is still untouched, the usage endpoint reports
/// `resets_at: null`, so there is no reset time to show.
///
/// Anchoring sends one throwaway Claude Code prompt as soon as the window is untouched, which pins
/// the window start and makes the reset time observable.
enum FiveHourAnchor {
    /// Short on purpose: it only has to be one billable request, not useful work.
    static let prompt = "hi"

    /// The usage endpoint does not report the window length, so the documented 5-hour session
    /// length is used as the cooldown. Two anchors can never belong to the same window.
    static let windowLength: TimeInterval = 5 * 60 * 60

    /// Seconds to wait for the CLI before treating an anchor attempt as failed.
    static let commandTimeout: TimeInterval = 120

    /// Whether Claude has a real start time for this window yet.
    ///
    /// Returns `nil` when the bucket lacks utilization or carries a reset time that cannot be
    /// parsed, because neither says anything reliable about the window start.
    static func isWindowStarted(_ bucket: UsageBucket, now: Date = Date()) -> Bool? {
        guard bucket.hasData else { return nil }
        guard bucket.resetsAt != nil else { return false }
        guard let resetDate = bucket.resetDate else { return nil }
        // A reset time in the past means the window expired and nothing has restarted it yet.
        return resetDate > now
    }
}

/// Why an anchor attempt was not made on this refresh.
enum FiveHourAnchorSkipReason: Equatable, Sendable {
    case disabled
    case alreadyRunning
    case noFiveHourWindow
    case unknownWindowStart
    case windowAlreadyStarted
    case cooldown
}

enum FiveHourAnchorDecision: Equatable, Sendable {
    case anchor
    case skip(FiveHourAnchorSkipReason)
}

/// Outcome of the most recent anchor attempt.
enum FiveHourAnchorOutcome: Equatable, Sendable {
    case idle
    case running
    case succeeded(Date)
    case failed(String)
}

/// Pure decision logic, kept out of the service so it can be unit tested without a live account.
enum FiveHourAnchorPolicy {
    static func decide(
        isEnabled: Bool,
        isRunning: Bool,
        fiveHour: UsageBucket?,
        lastAnchorAt: Date?,
        now: Date = Date()
    ) -> FiveHourAnchorDecision {
        guard isEnabled else { return .skip(.disabled) }
        guard !isRunning else { return .skip(.alreadyRunning) }
        guard let fiveHour else { return .skip(.noFiveHourWindow) }
        guard let isStarted = FiveHourAnchor.isWindowStarted(fiveHour, now: now) else {
            return .skip(.unknownWindowStart)
        }
        guard !isStarted else { return .skip(.windowAlreadyStarted) }

        if let lastAnchorAt, now.timeIntervalSince(lastAnchorAt) < FiveHourAnchor.windowLength {
            return .skip(.cooldown)
        }
        return .anchor
    }
}

struct FiveHourAnchorStatus: Equatable, Sendable {
    var isEnabled: Bool
    var outcome: FiveHourAnchorOutcome
    var lastAnchorAt: Date?
    /// Why the last evaluation did not anchor. Nil before the first evaluation.
    var skipReason: FiveHourAnchorSkipReason?

    var isRunning: Bool {
        outcome == .running
    }

    /// A running attempt and a failure the user may need to act on outrank the skip reason.
    /// Otherwise the row answers the question that matters: will it anchor, and why not.
    var title: String {
        switch outcome {
        case .running:
            return L("anchor.title.running")
        case .failed:
            return L("anchor.title.failed")
        case .succeeded, .idle:
            break
        }

        guard isEnabled else { return L("anchor.title.off") }

        switch skipReason {
        case .windowAlreadyStarted:
            return L("anchor.title.started")
        case .cooldown:
            return L("anchor.title.cooldown")
        case .noFiveHourWindow:
            return L("anchor.title.no_window")
        case .unknownWindowStart:
            return L("anchor.title.unknown")
        case .disabled, .alreadyRunning, .none:
            return L("anchor.title.waiting")
        }
    }

    var detail: String {
        switch outcome {
        case .running:
            return L("anchor.detail.running")
        case let .failed(message):
            return message
        case .succeeded, .idle:
            break
        }

        guard isEnabled else { return L("anchor.detail.off") }

        switch skipReason {
        case .windowAlreadyStarted:
            return L("anchor.detail.started") + anchoredSuffix
        case .cooldown:
            return L("anchor.detail.cooldown") + anchoredSuffix
        case .noFiveHourWindow:
            return L("anchor.detail.no_window")
        case .unknownWindowStart:
            return L("anchor.detail.unknown")
        case .disabled, .alreadyRunning, .none:
            return L("anchor.detail.waiting") + anchoredSuffix
        }
    }

    private var anchoredSuffix: String {
        guard let lastAnchorAt else { return "" }
        let formatter = DateFormatter()
        formatter.locale = activeLocale()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        // The separator lives in the localized string: CJK text needs none after a full stop.
        return L("anchor.last_anchored", formatter.string(from: lastAnchorAt))
    }
}

/// Persisted anchor settings. The service reads these on every evaluation, so a change made in
/// the settings panel takes effect on the next refresh.
enum FiveHourAnchorPreferences {
    enum Key {
        static let isEnabled = "fiveHourAnchorEnabled"
        static let cliPath = "fiveHourAnchorCLIPath"
        static let lastAnchorAt = "fiveHourAnchorLastAnchorAt"
    }

    private static var defaults: UserDefaults { .standard }

    /// Off by default: anchoring spends a Claude request, which the rest of the app never does.
    static var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    /// Nil means "discover the claude CLI automatically". The settings panel writes this key
    /// through `@AppStorage`.
    static var cliPath: String? {
        let value = defaults.string(forKey: Key.cliPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Persisted so a relaunch inside the same 5-hour window does not anchor a second time.
    static var lastAnchorAt: Date? {
        get {
            let seconds = defaults.double(forKey: Key.lastAnchorAt)
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastAnchorAt) }
    }
}
