// Compile alongside the production Capture and Vision sources (see scripts/compare_live.sh).
// Compares aggregate timings only. Never records video or posts input events.
import AppKit
import AVFoundation
import QuartzCore

final class Trial: CapturePipelineDelegate, VisionInferenceWorkerDelegate, @unchecked Sendable {
    let capture: CapturePipeline
    let worker = VisionInferenceWorker()
    let finished = DispatchSemaphore(value: 0)
    let control = DispatchQueue(label: "bench.control")
    let layout: CameraPixelLayout
    let waitForHand: Bool
    var consecutiveHands = 0
    var measuring = false
    var clearThumbs = 0
    var frames = 0
    var nowTimes = [Double]()
    var durations = [Double]()
    var latencies = [Double]()
    var estimated = 0
    var hands = 0
    init(_ layout: CameraPixelLayout, waitForHand: Bool) {
        self.waitForHand = waitForHand
        self.layout = layout
        capture = CapturePipeline(pixelLayout: layout)
        capture.delegate = self
        worker.delegate = self
    }
    func capturePipeline(_ pipeline: CapturePipeline, didOutput carrier: SampleCarrier) {
        worker.processMailbox(mailbox: pipeline.mailbox)
    }
    func capturePipelineDidInterrupted(_ pipeline: CapturePipeline) {}
    func capturePipelineInterruptionEnded(_ pipeline: CapturePipeline) {}

    func visionWorker(_ worker: VisionInferenceWorker, didProduce sample: HandSample?, carrier: SampleCarrier,
                      inferenceDuration: TimeInterval, mailboxWaitDuration: TimeInterval) {
        frames += 1
        if frames == 30 && waitForHand { print("Camera ready — waiting for a visible hand (\(layout.rawValue))") }
        guard frames > 30, nowTimes.count < 150 else { return }
        if waitForHand && !measuring {
            consecutiveHands = sample?.joint(.thumbTip, minConfidence: 0.45) != nil ? consecutiveHands + 1 : 0
            guard consecutiveHands >= 5 else { return }
            measuring = true
            print("Hand detected — sampling \(layout.rawValue)")
        }
        if sample?.joint(.thumbTip, minConfidence: 0.45) != nil { clearThumbs += 1 }
        let now = CACurrentMediaTime()
        nowTimes.append(now)
        durations.append(inferenceDuration * 1000)
        latencies.append((now - carrier.hostPresentationTime) * 1000)
        if carrier.isEstimatedTime { estimated += 1 }
        if sample != nil { hands += 1 }
        if durations.count == 150, let pb = CMSampleBufferGetImageBuffer(carrier.buffer) {
            let type = CVPixelBufferGetPixelFormatType(pb)
            let code = String(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: type >> ($0 * 8)) }, encoding: .ascii)!
            print(String(format: "%@ %@ %dx%d n=%d hands=%d thumbs=%d fps=%.2f vision50=%.2f vision95=%.2f cameraToVision50=%.2f cameraToVision95=%.2f estimated=%d bytes=%d drops=%d",
                         layout.rawValue, code, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb),
                         durations.count, hands, clearThumbs, 149 / (now - nowTimes[0]), percentile(durations, 0.5),
                         percentile(durations, 0.95), percentile(latencies, 0.5), percentile(latencies, 0.95),
                         estimated, CVPixelBufferGetDataSize(pb), capture.mailbox.droppedFrames))
            finished.signal()
        }
    }
    func run() {
        capture.start(completionQueue: control) { r in
            if case .failure(let e) = r { print(e); exit(2) }
        }
        guard finished.wait(timeout: .now() + (waitForHand ? 100 : 18)) == .success else { print("No complete trial before timeout"); exit(3) }
        let stopped = DispatchSemaphore(value: 0)
        capture.stop(completionQueue: control) { stopped.signal() }
        _ = stopped.wait(timeout: .now() + 4)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    values.sorted()[Int(Double(values.count - 1) * p)]
}

@main struct LiveBenchmark {
    static func main() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("Camera access is required under an already authorized host.")
            exit(1)
        }
        // AppKit and camera notifications continue receiving main-thread callbacks.
        DispatchQueue.global().async {
            for layout in [CameraPixelLayout.bgra, .nativeYUV, .nativeYUV, .bgra] {
                Trial(layout, waitForHand: CommandLine.arguments.contains("--with-hand")).run()
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}
