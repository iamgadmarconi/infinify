import AppKit
import QuartzCore

/// What the trackpad says under the hand while a window is dragged or resized (Settings › Windows ›
/// "Trackpad haptics"). The Mac offers three taps — alignment, generic and level change, light to
/// heavy — and plays them only while a finger is on a Force Touch trackpad, so everything here happens
/// inside a drag and nothing plays for a mouse, after letting go, or with haptic feedback off in the
/// Mac's trackpad settings.
///
/// Each thing that can happen gets a cue of its own, told apart by weight and rhythm rather than
/// loudness, and modelled on what the same thing feels like in the hand:
///
/// - `detent`: an edge catches an alignment guide. One light tap, a drawer finding its stop.
/// - `bump`: the hand runs into a neighbour and starts shoving it. One tap of ordinary weight, a block
///   nudging a block. Only for what the hand itself hits: what the neighbour shoves behind it is weight,
///   not a knock, and stays silent.
/// - `cushion`: like poles meet. Repelling magnets never touch, you feel a springy flutter, so two
///   light taps close together.
/// - `catch`: an opposite pole comes within reach and is drawn in. A pull that grows: a light tap, then
///   a heavier one.
/// - `bond`: the pulled window arrives and the two lock together. One heavy tap, the clack of magnets
///   meeting. The one cue that goes through whatever else is playing.
/// - `split`: ⌘-drag prises a member off its group. The catch backwards: a tap, then a lighter one, the
///   hold giving way.
///
/// `Gate` keeps them from chattering: a cue won't start on the heels of another, a window that was just
/// bumped isn't bumped again for a moment, a guide re-caught at once is silent, and a sweep through a
/// cluster can't tick more than a few times a second. `Player` puts the admitted cue on the trackpad.
enum Haptics {
    /// The Mac's three taps, light to heavy.
    enum Tap: CaseIterable, Equatable {
        case light, medium, heavy

        var pattern: NSHapticFeedbackManager.FeedbackPattern {
            switch self {
            case .light: return .alignment
            case .medium: return .generic
            case .heavy: return .levelChange
            }
        }
    }

    /// One tap of a cue, `delay` seconds after the cue starts.
    struct Step: Equatable {
        let delay: TimeInterval
        let tap: Tap
    }

    enum Cue: CaseIterable, Hashable {
        case detent, bump, cushion, `catch`, bond, split

        var steps: [Step] {
            switch self {
            case .detent: return [Step(delay: 0, tap: .light)]
            case .bump: return [Step(delay: 0, tap: .medium)]
            case .cushion: return [Step(delay: 0, tap: .light), Step(delay: 0.045, tap: .light)]
            case .catch: return [Step(delay: 0, tap: .light), Step(delay: 0.07, tap: .medium)]
            case .bond: return [Step(delay: 0, tap: .heavy)]
            case .split: return [Step(delay: 0, tap: .medium), Step(delay: 0.06, tap: .light)]
            }
        }

        /// From the first tap to the last.
        var duration: TimeInterval { steps.last?.delay ?? 0 }

        /// How long the same thing (the same window hit, the same guide caught) stays silent after it
        /// played: the hand hovering at the edge of a push would otherwise rattle.
        var cooldown: TimeInterval {
            switch self {
            case .detent: return 0.25
            case .bump, .cushion: return 0.35
            case .catch: return 0.5
            case .bond, .split: return 0.3
            }
        }
    }

    /// Decides which cues play, by time alone, so it can be tested. `key` tells one instance of a cue
    /// from another: the window bumped, the guide caught.
    struct Gate {
        /// A cue starts no sooner than this after the last one ended…
        static let spacing: TimeInterval = 0.06
        /// …and `bond` no sooner than this after the last tap, the least the trackpad needs to tell two
        /// apart.
        static let interrupt: TimeInterval = 0.03
        /// At most this many cues in any `budgetWindow` seconds; `bond` is exempt.
        static let budget = 6
        static let budgetWindow: TimeInterval = 1

        private var lastStart: TimeInterval = -.infinity
        private var lastEnd: TimeInterval = -.infinity
        private var starts: [TimeInterval] = []
        private var played: [Key: TimeInterval] = [:]

        private struct Key: Hashable {
            let cue: Cue
            let id: AnyHashable?
        }

        init() {}

        /// Whether `cue` may start at `now`, and if so, records that it did.
        mutating func admit(_ cue: Cue, key: AnyHashable? = nil, at now: TimeInterval) -> Bool {
            let k = Key(cue: cue, id: key)
            if let last = played[k], now - last < cue.cooldown { return false }
            if cue == .bond {
                // Through anything but a tap that just went; a lighter cue in progress is cut short.
                guard now - lastStart >= Gate.interrupt else { return false }
            } else {
                guard now - lastEnd >= Gate.spacing else { return false }
                starts.removeAll { now - $0 >= Gate.budgetWindow }
                guard starts.count < Gate.budget else { return false }
            }
            starts.append(now)
            played[k] = now
            lastStart = now
            lastEnd = now + cue.duration
            return true
        }

        /// Forgets what played: a new gesture starts clean, so its first contact is always felt.
        mutating func reset() {
            lastStart = -.infinity
            lastEnd = -.infinity
            starts = []
            played = [:]
        }
    }

    /// Plays admitted cues on the trackpad. The first tap goes with the next frame, so the tick lands
    /// as the guide or the push is drawn; the rest follow on their delays. A new cue cancels the taps
    /// a previous one still had to come, which only a `bond` does within a cue's duration.
    @MainActor
    final class Player {
        static let shared = Player()

        private var gate = Gate()
        private var generation = 0

        /// `perform(tap, immediately)`: the trackpad, or a test's stand-in.
        var perform: (Tap, Bool) -> Void = { tap, now in
            NSHapticFeedbackManager.defaultPerformer.perform(tap.pattern, performanceTime: now ? .now : .drawCompleted)
        }

        /// Plays `cue` if the gate lets it, and says whether it did.
        @discardableResult
        func play(_ cue: Cue, key: AnyHashable? = nil, at time: TimeInterval = CACurrentMediaTime()) -> Bool {
            guard Settings.haptics, gate.admit(cue, key: key, at: time) else { return false }
            generation += 1
            let mine = generation
            for step in cue.steps {
                if step.delay <= 0 {
                    perform(step.tap, false)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                        guard let self, self.generation == mine else { return }
                        self.perform(step.tap, true)
                    }
                }
            }
            return true
        }

        /// A gesture begins: nothing from the last one holds a cue back, and nothing from it is still
        /// to come.
        func begin() {
            gate.reset()
            generation += 1
        }
    }
}
