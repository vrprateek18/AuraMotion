// Run with swift scripts/compare_vision_formats.swift /path/to/hand-image.jpg
// Construct identical letterboxed 720p scenes before timing Vision.
import CoreImage
import Foundation
import QuartzCore
import VideoToolbox
import Vision

func buffer(_ format: OSType) -> CVPixelBuffer {
    var output: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, 1280, 720, format,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output) == 0)
    return output!
}

guard CommandLine.arguments.count == 2,
      let image = CIImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    fatalError("Supply a photograph with a visible hand")
}
let scale = min(1280 / image.extent.width, 720 / image.extent.height)
let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
let context = CIContext()
var transfer: VTPixelTransferSession?
precondition(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == 0)
let formats = [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
let labels = ["BGRA", "420v", "420f"]
var scenes: [[CVPixelBuffer]] = []
for shift in [-60.0, -20.0, 20.0, 60.0] {
    let frame = resized.transformed(by: CGAffineTransform(translationX: (1280 - resized.extent.width) / 2 + shift, y: 0))
        .composited(over: CIImage(color: .black)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    let rgba = buffer(formats[0])
    context.render(frame, to: rgba)
    scenes.append([rgba] + formats.dropFirst().map {
        let yuv = buffer($0)
        precondition(VTPixelTransferSessionTransferImage(transfer!, from: rgba, to: yuv) == 0)
        return yuv
    })
}
let request = VNDetectHumanHandPoseRequest()
request.maximumHandCount = 1
var times = Array(repeating: [Double](), count: 3)
var detections = [0, 0, 0]
var thumbs = Array(repeating: [Int: CGPoint](), count: 3)
var iterations = [0, 0, 0]
for index in [0, 1, 2, 2, 1, 0, 1, 0, 2, 2, 0, 1] {
    for n in 0..<52 {
        let scene = n % scenes.count
        try autoreleasepool {
            let start = CACurrentMediaTime()
            try VNImageRequestHandler(cvPixelBuffer: scenes[scene][index], orientation: .up).perform([request])
            let elapsed = (CACurrentMediaTime() - start) * 1000
            guard n >= 4 else { return }
            iterations[index] += 1
            times[index].append(elapsed)
            if let thumb = try request.results?.first?.recognizedPoint(.thumbTip), thumb.confidence >= 0.45 {
                detections[index] += 1
                thumbs[index][scene] = thumb.location
            }
        }
    }
}
for i in 0..<3 {
    let sorted = times[i].sorted()
    let drift = thumbs[0].compactMap { entry -> Double? in
        guard let other = thumbs[i][entry.key] else { return nil }
        return hypot((other.x - entry.value.x) * 1280, (other.y - entry.value.y) * 720)
    }.max() ?? .nan
    print(String(format: "%@ n=%d detectableThumb=%d p50=%.3f ms p95=%.3f ms maxThumbDifference=%.2f image px",
                 labels[i], iterations[i], detections[i], sorted[sorted.count/2], sorted[sorted.count*95/100], drift))
}
