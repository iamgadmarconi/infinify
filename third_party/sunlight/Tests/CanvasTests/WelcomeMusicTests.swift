import XCTest
@testable import Canvas

/// The welcome music: ten seconds, silent at both ends, one peak on the bloom, and a WAV that says so.
final class WelcomeMusicTests: XCTestCase {
    func testRendersTenSecondsThatStartAndEndSilent() {
        let (left, right) = WelcomeMusic.render()
        XCTAssertEqual(left.count, Int(WelcomeMusic.duration * WelcomeMusic.sampleRate))
        XCTAssertEqual(right.count, left.count)
        XCTAssertTrue(left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite))
        let loudest = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        XCTAssertEqual(loudest, WelcomeMusic.peak, accuracy: 0.001)
        XCTAssertEqual(left[0], 0)
        XCTAssertLessThan(abs(left[left.count - 1]), 0.0001)
        XCTAssertLessThan(abs(right[right.count - 1]), 0.0001)
        // Something to hear just after the bloom, and the two sides not the same.
        let middle = Int((WelcomeMusic.climax + 0.5) * WelcomeMusic.sampleRate)
        XCTAssertGreaterThan(left[middle..<middle + 4410].map(abs).max() ?? 0, 0.05)
        XCTAssertNotEqual(left[middle], right[middle])
    }

    /// It builds: quiet early, louder just before the bloom, and loudest in the second after it.
    func testGathersToOnePeakOnTheBloom() {
        let (left, right) = WelcomeMusic.render()
        let rate = WelcomeMusic.sampleRate
        func level(_ from: Double, _ to: Double) -> Float {
            let range = Int(from * rate)..<Int(to * rate)
            return range.map { max(abs(left[$0]), abs(right[$0])) }.max() ?? 0
        }
        let loudestAt = Double(left.indices.max { max(abs(left[$0]), abs(right[$0])) < max(abs(left[$1]), abs(right[$1])) }!) / rate
        XCTAssertEqual(loudestAt, WelcomeMusic.climax + 0.5, accuracy: 0.5)
        XCTAssertLessThan(level(0.5, 1.0), level(2.0, 2.6))
        XCTAssertLessThan(level(2.0, 2.6), level(WelcomeMusic.climax, WelcomeMusic.climax + 0.5))
        XCTAssertLessThan(level(7, 8), level(WelcomeMusic.climax, WelcomeMusic.climax + 0.5))
    }

    func testThirdArrivesOnTheBloomAndTheLineLeadsThere() {
        XCTAssertEqual(WelcomeMusic.third(at: WelcomeMusic.climax - 0.3), 0)
        XCTAssertEqual(WelcomeMusic.third(at: WelcomeMusic.climax + 0.3), 1)
        XCTAssertLessThan(WelcomeMusic.line.last!.time, WelcomeMusic.climax)
        XCTAssertTrue(WelcomeMusic.chimes.contains { $0.time == WelcomeMusic.climax })
        XCTAssertLessThan(WelcomeMusic.brightness(at: 0.5), WelcomeMusic.brightness(at: WelcomeMusic.climax))
        XCTAssertLessThanOrEqual(WelcomeMusic.brightness(at: WelcomeMusic.duration), 2100)
        XCTAssertEqual(WelcomeMusic.envelope(at: 0), 0)
        XCTAssertEqual(WelcomeMusic.envelope(at: WelcomeMusic.climax), 1)
        // The fade starts well after the bloom and takes its time.
        XCTAssertGreaterThan(WelcomeMusic.fadeFrom, WelcomeMusic.climax + 1)
        XCTAssertGreaterThanOrEqual(WelcomeMusic.duration - WelcomeMusic.fadeFrom, 3.5)
        XCTAssertGreaterThan(WelcomeMusic.envelope(at: WelcomeMusic.duration - 1), 0.01)
        XCTAssertEqual(WelcomeMusic.end(at: WelcomeMusic.duration), 0)
    }

    /// It closes on a high D major chord after the chimes have thinned out, its top D ringing longest,
    /// and the last second is quiet but still sounding.
    func testClosesOnAHighMajorChord() {
        let chord = WelcomeMusic.cadenceChord
        XCTAssertGreaterThan(WelcomeMusic.cadence, WelcomeMusic.climax + 1)
        XCTAssertTrue(WelcomeMusic.chimes.allSatisfy { $0.time < WelcomeMusic.cadence })
        XCTAssertGreaterThan(chord.map(\.frequency).min()!, 400)
        let top = chord.max { $0.frequency < $1.frequency }!
        XCTAssertEqual(top.ring, chord.map(\.ring).max())
        // D, F♯ and A only.
        let pitchClasses = Set(chord.map { Int((12 * log2($0.frequency / 293.66)).rounded()) % 12 })
        XCTAssertEqual(pitchClasses, [0, 4, 7])
        XCTAssertEqual(WelcomeMusic.colour(at: WelcomeMusic.cadence), 0)

        let (left, _) = WelcomeMusic.render()
        let rate = WelcomeMusic.sampleRate
        let lastSecond = left[Int((WelcomeMusic.duration - 1) * rate)..<Int((WelcomeMusic.duration - 0.6) * rate)].map(abs).max() ?? 0
        XCTAssertGreaterThan(lastSecond, 0.002)
        XCTAssertLessThan(lastSecond, WelcomeMusic.peak / 4)
        let close = left[Int(WelcomeMusic.cadence * rate)..<Int((WelcomeMusic.cadence + 0.5) * rate)].map(abs).max() ?? 0
        let before = left[Int((WelcomeMusic.cadence - 0.4) * rate)..<Int(WelcomeMusic.cadence * rate)].map(abs).max() ?? 0
        XCTAssertGreaterThan(close, before)
    }

    /// The page comes in part by part, in order, each on a chime: the sun from an early one, landing on
    /// the reveal chime; the headline and subheadline together on it; the rail on a later one; Get
    /// Started on the close; Set Up Later last of all.
    func testThePageComesInOnTheMusic() {
        let moments = WelcomeReveal.moments
        XCTAssertEqual(moments.map(\.reveal), [.sun, .headline, .chrome, .start, .later])
        XCTAssertEqual(moments.map(\.at), moments.map(\.at).sorted())
        for moment in moments.dropLast(2) {
            XCTAssertTrue(WelcomeMusic.chimes.contains { $0.time == moment.at }, "\(moment.reveal) on a chime")
        }
        XCTAssertEqual(moments[1].at, WelcomeMusic.climax)
        XCTAssertEqual(moments[3].at, WelcomeMusic.cadence)
        // Set Up Later last, once Get Started has settled, and in before the music ends.
        XCTAssertEqual(moments.last!.reveal, .later)
        XCTAssertGreaterThanOrEqual(moments.last!.at, WelcomeMusic.cadence + Arrival.buttonDuration)
        XCTAssertLessThan(moments.last!.at + Arrival.laterDuration, WelcomeMusic.duration)
        XCTAssertEqual(moments[0].at + Arrival.sunDuration, WelcomeMusic.climax, accuracy: 0.001)
        // Get Started unfolds slowly, and is in well before the music ends.
        XCTAssertGreaterThanOrEqual(Arrival.buttonDuration, 1.5)
        XCTAssertLessThan(WelcomeMusic.cadence + Arrival.buttonDuration, WelcomeMusic.duration - 2)
    }

    func testWAVHeaderMatchesTheSamples() {
        let wav = WelcomeMusic.wav()
        let frames = Int(WelcomeMusic.duration * WelcomeMusic.sampleRate)
        XCTAssertEqual(wav.count, 44 + frames * 4)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
    }
}
