import MarginCore
import XCTest

final class TimerScaleTests: XCTestCase {
    func testScaleHas26NotchesFrom1To90() {
        XCTAssertEqual(TimerScale.notches, 26)
        XCTAssertEqual(TimerScale.minutes(atNotch: 0), 0)
        XCTAssertEqual(TimerScale.minutes(atNotch: 1), 1)
        XCTAssertEqual(TimerScale.minutes(atNotch: 10), 10)
        XCTAssertEqual(TimerScale.minutes(atNotch: 11), 15)
        XCTAssertEqual(TimerScale.minutes(atNotch: 26), 90)
        // Out of range clamps rather than crashing.
        XCTAssertEqual(TimerScale.minutes(atNotch: 40), 90)
        XCTAssertEqual(TimerScale.minutes(atNotch: -3), 0)
    }

    func testNotchAndMinutesRoundTrip() {
        for notch in 0...TimerScale.notches {
            XCTAssertEqual(TimerScale.notch(nearest: Double(TimerScale.minutes(atNotch: notch))), notch)
        }
    }

    func testNearestNotch() {
        XCTAssertEqual(TimerScale.minutes(atNotch: TimerScale.notch(nearest: 24.2)), 25)
        XCTAssertEqual(TimerScale.minutes(atNotch: TimerScale.notch(nearest: 12.5)), 15)
        XCTAssertEqual(TimerScale.minutes(atNotch: TimerScale.notch(nearest: 12)), 10)
        XCTAssertEqual(TimerScale.minutes(atNotch: TimerScale.notch(nearest: 500)), 90)
    }

    func testMinutesStepperFollowsTheScaleAndStopsAtOne() {
        XCTAssertEqual(TimerScale.step(25, up: true), 30)
        XCTAssertEqual(TimerScale.step(10, up: true), 15)
        XCTAssertEqual(TimerScale.step(15, up: false), 10)
        XCTAssertEqual(TimerScale.step(1, up: false), 1)
        XCTAssertEqual(TimerScale.step(90, up: true), 90)
    }
}

final class TimerDialTests: XCTestCase {
    private let spacing = 0.03

    func testCountsNotchesFromTheStart() {
        var dial = TimerDial(startMinutes: 25, origin: 0.5, spacing: spacing)
        XCTAssertEqual(dial.minutes, 25)
        XCTAssertFalse(dial.moved)
        XCTAssertTrue(dial.move(to: 0.5 + spacing))
        XCTAssertEqual(dial.minutes, 30)
        XCTAssertFalse(dial.move(to: 0.5 + spacing * 1.2))
        XCTAssertTrue(dial.move(to: 0.5 - spacing * 2))
        XCTAssertEqual(dial.minutes, 15)
        XCTAssertTrue(dial.moved)
    }

    func testClampsAndReversesAtOnceAtTheEnds() {
        var dial = TimerDial(startMinutes: 85, origin: 0, spacing: spacing)
        _ = dial.move(to: spacing * 10)          // far past 90
        XCTAssertEqual(dial.minutes, 90)
        XCTAssertTrue(dial.move(to: spacing * 9)) // one notch back responds straight away
        XCTAssertEqual(dial.minutes, 85)

        var low = TimerDial(startMinutes: 2, origin: 0, spacing: spacing)
        _ = low.move(to: -spacing * 10)
        XCTAssertEqual(low.minutes, 0)
        XCTAssertEqual(TimerDial.hint(minutes: low.minutes), "Lift to cancel")
        XCTAssertTrue(low.move(to: -spacing * 9))
        XCTAssertEqual(low.minutes, 1)
        XCTAssertEqual(TimerDial.hint(minutes: 1), "Lift to start")
    }

    func testShiftKeepsTheValueAfterADropout() {
        var dial = TimerDial(startMinutes: 5, origin: 0, spacing: spacing)
        _ = dial.move(to: spacing * 2)
        dial.shift(by: 0.05)
        XCTAssertFalse(dial.move(to: spacing * 2 + 0.05))
        XCTAssertEqual(dial.minutes, 7)
    }
}

final class TimerMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testStartRemembersTheLength() {
        var m = TimerMachine()
        XCTAssertEqual(m.dialStartMinutes(now: t0), 25)
        m.start(minutes: 10, now: t0)
        XCTAssertEqual(m.state, .running(endsAt: at(600)))
        XCTAssertEqual(m.lastMinutes, 10)
        XCTAssertEqual(m.remaining(now: at(90)), 510)
        // The dial starts at the time left, rounded up.
        XCTAssertEqual(m.dialStartMinutes(now: at(90)), 9)
    }

    func testPauseAndResume() {
        var m = TimerMachine()
        m.start(minutes: 5, now: t0)
        m.pauseResume(now: at(60))
        XCTAssertEqual(m.state, .paused(remaining: 240))
        // Paused time doesn't run down.
        XCTAssertEqual(m.remaining(now: at(1000)), 240)
        XCTAssertFalse(m.refresh(now: at(1000)))
        m.pauseResume(now: at(1000))
        XCTAssertEqual(m.state, .running(endsAt: at(1240)))
    }

    func testAdjustingWhileRunningAndCancelling() {
        var m = TimerMachine()
        m.start(minutes: 25, now: t0)
        m.setFromDial(minutes: 40, now: at(120))
        XCTAssertEqual(m.state, .running(endsAt: at(120 + 2400)))
        m.setFromDial(minutes: 0, now: at(200))
        XCTAssertEqual(m.state, .idle)
        // Cancelling keeps the last length for next time.
        XCTAssertEqual(m.lastMinutes, 40)
    }

    func testDialOnAPausedTimerRunsItAgain() {
        var m = TimerMachine()
        m.start(minutes: 25, now: t0)
        m.pauseResume(now: at(60))
        m.setFromDial(minutes: 20, now: at(100))
        XCTAssertEqual(m.state, .running(endsAt: at(1300)))
    }

    func testRingsAtTheEndAndDismisses() {
        var m = TimerMachine()
        m.start(minutes: 1, now: t0)
        XCTAssertFalse(m.refresh(now: at(59)))
        XCTAssertTrue(m.refresh(now: at(60)))
        XCTAssertEqual(m.state, .ringing(since: at(60)))
        XCTAssertFalse(m.refresh(now: at(61)), "only reports the change once")
        XCTAssertNil(m.remaining(now: at(61)))
        m.dismiss()
        XCTAssertEqual(m.state, .idle)
    }

    func testExpiringDuringSleepRingsOnWakeForTheFullTime() {
        var m = TimerMachine()
        m.start(minutes: 5, now: t0)
        // Asleep for three hours; the first look after wake finds it over.
        let wake = at(3 * 3600)
        XCTAssertTrue(m.refresh(now: wake))
        XCTAssertEqual(m.state, .ringing(since: wake))
        XCTAssertTrue(m.isAlarmSounding(now: wake.addingTimeInterval(1), limit: 120))
    }

    func testAutoStopLeavesItRingingButQuiet() {
        var m = TimerMachine()
        m.start(minutes: 1, now: t0)
        m.refresh(now: at(60))
        let limit = AlarmIntensity.normal.pattern.stopsAfter
        XCTAssertTrue(m.isAlarmSounding(now: at(60 + limit - 1), limit: limit))
        XCTAssertFalse(m.isAlarmSounding(now: at(60 + limit), limit: limit))
        // Still there for "Timer done" until dismissed.
        XCTAssertEqual(m.state, .ringing(since: at(60)))
    }

    func testPauseResumeWhileRingingDismisses() {
        var m = TimerMachine()
        m.start(minutes: 1, now: t0)
        m.pauseResume(now: at(65))   // the refresh inside notices it has rung
        XCTAssertEqual(m.state, .idle)
    }

    func testDismissNeverCancelsARunningTimer() {
        var m = TimerMachine()
        m.start(minutes: 3, now: t0)
        m.dismiss()
        XCTAssertEqual(m.state, .running(endsAt: at(180)))
    }

    func testPreviewLengthDoesntChangeTheDialStart() {
        var m = TimerMachine()
        m.start(duration: 10, now: t0)
        XCTAssertEqual(m.state, .running(endsAt: at(10)))
        XCTAssertEqual(m.lastMinutes, 25)
    }

    func testRestoresAfterRelaunch() throws {
        for state: TimerState in [.idle, .running(endsAt: at(300)), .paused(remaining: 42), .ringing(since: at(5))] {
            var m = TimerMachine()
            m.start(minutes: 15, now: t0)
            switch state {
            case .idle: m.cancel()
            case .running: break
            case .paused: m.pauseResume(now: at(900 - 42))
            case .ringing: m.refresh(now: at(5)); m.start(minutes: 15, now: t0); m.refresh(now: at(900))
            }
            let restored = try JSONDecoder().decode(TimerMachine.self, from: JSONEncoder().encode(m))
            XCTAssertEqual(restored, m)
            XCTAssertEqual(restored.lastMinutes, 15)
        }
        // A timer that ended while Margin was quit rings on the first refresh after launch.
        var m = TimerMachine()
        m.start(minutes: 1, now: t0)
        var restored = try JSONDecoder().decode(TimerMachine.self, from: JSONEncoder().encode(m))
        XCTAssertTrue(restored.refresh(now: at(500)))
    }

    func testUnreadableSavedTimerFallsBackToIdle() throws {
        let m = try JSONDecoder().decode(TimerMachine.self, from: Data(#"{"state":{"bogus":{}}}"#.utf8))
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.lastMinutes, 25)
    }

    func testCountdownText() {
        XCTAssertEqual(TimerDisplay.countdown(24 * 60 + 12), "24:12")
        XCTAssertEqual(TimerDisplay.countdown(9.2), "0:10")
        XCTAssertEqual(TimerDisplay.countdown(3600), "60:00")
        XCTAssertEqual(TimerDisplay.countdown(84 * 60), "1h 24m")
        XCTAssertEqual(TimerDisplay.refreshInterval(3599), 1)
        XCTAssertEqual(TimerDisplay.refreshInterval(4000), 60)
    }
}

final class AlarmPatternTests: XCTestCase {
    func testGentle() {
        let p = AlarmIntensity.gentle.pattern
        XCTAssertEqual(p.pulseOffsets, [0])
        XCTAssertFalse(p.strong)
        XCTAssertEqual(p.repeatEvery, 4)
        XCTAssertEqual(p.stopsAfter, 60)
    }

    func testNormal() {
        let p = AlarmIntensity.normal.pattern
        XCTAssertEqual(p.pulseOffsets.count, 3)
        XCTAssertEqual(p.pulseOffsets[2], 0.24, accuracy: 1e-9)
        XCTAssertTrue(p.strong)
        XCTAssertEqual(p.repeatEvery, 4)
        XCTAssertEqual(p.stopsAfter, 120)
    }

    func testInsistent() {
        let p = AlarmIntensity.insistent.pattern
        XCTAssertEqual(p.pulseOffsets.count, 5)
        XCTAssertEqual(p.pulseOffsets[4], 0.4, accuracy: 1e-9)
        XCTAssertTrue(p.strong)
        XCTAssertEqual(p.repeatEvery, 2)
        XCTAssertEqual(p.stopsAfter, 300)
    }

    func testBurstsRepeatOnTheInterval() {
        let p = AlarmIntensity.normal.pattern
        XCTAssertTrue(p.burstDue(lastBurst: nil, now: 10))
        XCTAssertFalse(p.burstDue(lastBurst: 10, now: 13.9))
        XCTAssertTrue(p.burstDue(lastBurst: 10, now: 14))
    }

    func testEveryBurstFitsInsideItsInterval() {
        for intensity in AlarmIntensity.allCases {
            let p = intensity.pattern
            XCTAssertLessThan(p.pulseOffsets.last ?? 0, p.repeatEvery, intensity.title)
        }
    }

    func testSettingsDecodeWithMissingFields() throws {
        let s = try JSONDecoder().decode(TimerSettings.self, from: Data(#"{"playSound":true}"#.utf8))
        XCTAssertEqual(s.alarm, .normal)
        XCTAssertTrue(s.playSound)
        XCTAssertFalse(s.showNotification)
        XCTAssertNil(s.startShortcut)
        var full = TimerSettings()
        full.alarm = .insistent
        full.endShortcut = "Focus Off"
        XCTAssertEqual(try JSONDecoder().decode(TimerSettings.self, from: JSONEncoder().encode(full)), full)
    }
}
