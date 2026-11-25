// swiftc -O scripts/compare_presentation.swift Sources/AuraMotionCore/Tracking/PresentationTrack.swift \
//   Sources/AuraMotionCore/Domain/{HandJoint,HandSample,EstimatedHandedness}.swift -o /tmp/compare-presentation
import AppKit
import QuartzCore

@main @MainActor final class PresentationBenchmark: NSObject {
    var track = PresentationTrack(maxLead: 12)
    var source = CGPoint.zero
    var start = 0.0
    var measurementSlot = -1
    var tickTimes = [Double]()
    var oldError = [Double]()
    var newError = [Double]()
    var previousOld: CGPoint?
    var previousNew: CGPoint?
    var updates = (old: 0, new: 0)
    var observations = 0
    var displayLink: CADisplayLink?
    var timer: Timer?

    // Includes direction changes, smooth acceleration, and a stationary interval.
    func truth(_ t: Double) -> CGPoint {
        let phase = min(3, max(0, t)) + max(0, t - 4)
        return CGPoint(x: 500 + 90 * sin(phase * 2.4), y: 300 + 40 * sin(phase * 3.1))
    }
    func measure() {
        let now = CACurrentMediaTime()
        let slot = Int((now - start) * 30)
        guard slot > measurementSlot else { return }
        measurementSlot = slot
        let stamp = start + Double(slot) / 30
        source = truth(stamp - start)
        track.observe(source, timestamp: stamp, received: now)
        observations += 1
    }

    @objc func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let target = link.targetTimestamp
        if target - start >= 11 {
            let gaps = zip(tickTimes.dropFirst(), tickTimes).map { ($0 - $1) * 1000 }
            func p(_ xs: [Double], _ q: Double) -> Double { xs.sorted()[Int(Double(xs.count - 1) * q)] }
            print(String(format: "10 s: ticks=%d measured=%d observedFPS=%.2f callbackGapP99=%.2f ms; distinct baseline=%d smooth=%d; errorP50=%.2f -> %.2f pt; errorP95=%.2f -> %.2f pt",
                tickTimes.count, observations, Double(tickTimes.count - 1)/(tickTimes.last! - tickTimes.first!), p(gaps,0.99),
                updates.old, updates.new, p(oldError,0.5), p(newError,0.5), p(oldError,0.95), p(newError,0.95)))
            exit(0)
        }
        if target - start < 1 { observations = 0; return }
        guard let presented = track.position(at: target) else { return }
        tickTimes.append(now)
        let reference = truth(target - start)
        oldError.append(hypot(source.x - reference.x, source.y - reference.y))
        newError.append(hypot(presented.x - reference.x, presented.y - reference.y))
        if source != previousOld { updates.old += 1 }
        if presented != previousNew { updates.new += 1 }
        previousOld = source
        previousNew = presented
    }
    static func main() {
        _ = NSApplication.shared
        let run = PresentationBenchmark()
        guard let screen = NSScreen.screens.first else { print("No display"); exit(1) }
        let link = screen.displayLink(target: run, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        run.displayLink = link
        run.start = CACurrentMediaTime()
        // Wake slightly more often to deliver each simulated 30 Hz sample promptly.
        run.timer = Timer.scheduledTimer(withTimeInterval: 1.0/120, repeats: true) { _ in
            MainActor.assumeIsolated { run.measure() }
        }
        link.add(to: .main, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(14))
        print("Display link did not complete"); exit(2)
    }
}
