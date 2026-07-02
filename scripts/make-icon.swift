// Regenerates Resources/AppIcon.icns from app_icon.png (repo root).
// Lifts the subject off the baked-in checkerboard background with Vision,
// crops to its bounds, centers it on a square 1024 canvas (~82% content,
// per the macOS icon grid), then emits the iconset next to the output.
//
// Run via scripts/make-icon.sh (needs macOS 14+ for subject lifting).

import AppKit
import Vision
import CoreImage

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let srcURL = root.appendingPathComponent("app_icon.png")
let outURL = root.appendingPathComponent("build/icon/AppIcon-1024.png")

guard let src = CIImage(contentsOf: srcURL) else {
    fatalError("cannot read \(srcURL.path)")
}

// 1. Subject mask.
let handler = VNImageRequestHandler(ciImage: src)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let observation = request.results?.first else {
    fatalError("Vision found no subject in app_icon.png")
}
let maskBuffer = try observation.generateScaledMaskForImage(
    forInstances: observation.allInstances, from: handler
)
let mask = CIImage(cvPixelBuffer: maskBuffer)

// 2. Cut out: image where mask, transparent elsewhere.
let blend = CIFilter(name: "CIBlendWithMask")!
blend.setValue(src, forKey: kCIInputImageKey)
blend.setValue(CIImage(color: .clear).cropped(to: src.extent), forKey: kCIInputBackgroundImageKey)
blend.setValue(mask, forKey: kCIInputMaskImageKey)
let cutout = blend.outputImage!

let context = CIContext()
guard let cg = context.createCGImage(cutout, from: src.extent) else {
    fatalError("render failed")
}

// 3. Alpha bounding box.
let w = cg.width, h = cg.height
var data = [UInt8](repeating: 0, count: w * h)   // alpha-only bitmap
let alphaCtx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                         bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                         bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
alphaCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where data[y * w + x] > 8 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("empty mask") }
let bbox = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("subject bbox: \(Int(bbox.width))×\(Int(bbox.height)) at (\(minX),\(minY))")
let subject = cg.cropping(to: bbox)!

// 4. Compose 1024×1024 with the subject scaled to the icon grid (~82%).
let canvas = 1024
let content = Int(Double(canvas) * 0.82)
let scale = min(Double(content) / Double(subject.width),
                Double(content) / Double(subject.height))
let dw = Int(Double(subject.width) * scale)
let dh = Int(Double(subject.height) * scale)

let outCtx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                       bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
outCtx.interpolationQuality = .high
outCtx.draw(subject, in: CGRect(x: (canvas - dw) / 2, y: (canvas - dh) / 2,
                                width: dw, height: dh))
let final = outCtx.makeImage()!

try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: final)
try rep.representation(using: .png, properties: [:])!.write(to: outURL)
print("wrote \(outURL.path)")
