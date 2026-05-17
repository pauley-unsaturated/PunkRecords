#!/usr/bin/env swift
import Foundation
import AppKit
import CoreGraphics

// snapshot-diff.swift
//
// Tolerant PNG comparison for SwiftUI preview snapshots.
//
// Usage:
//   ./snapshot-diff.swift <baseline.png> <fresh.png> [maxMeanDiff=2.0]
//
// Decodes both images, asserts they share dimensions, then computes the
// mean per-channel absolute difference (0–255 scale). Exits 0 if the
// mean difference is below the threshold, 1 otherwise.
//
// Why this and not `cmp`: RenderPreview's PNG output isn't byte-identical
// across runs even with no source changes (metadata + compression noise),
// so any byte-level diff fails the moment you re-render. Pixel-decoded
// comparison with a small threshold is the right granularity for catching
// real visual regressions.

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func loadImage(_ path: String) -> (CGImage, width: Int, height: Int) {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        die("Cannot read \(path)")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        die("Cannot decode \(path) as an image")
    }
    return (image, image.width, image.height)
}

func rawRGBA(_ image: CGImage) -> Data {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var buffer = Data(count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    die("usage: snapshot-diff.swift <baseline.png> <fresh.png> [maxMeanDiff=2.0]")
}
let baselinePath = args[1]
let freshPath = args[2]
let threshold = Double(args.count > 3 ? args[3] : "2.0") ?? 2.0

let baseline = loadImage(baselinePath)
let fresh = loadImage(freshPath)

guard baseline.width == fresh.width, baseline.height == fresh.height else {
    die("size mismatch: baseline \(baseline.width)×\(baseline.height) vs fresh \(fresh.width)×\(fresh.height)")
}

let a = rawRGBA(baseline.0)
let b = rawRGBA(fresh.0)
let count = min(a.count, b.count)

// Per-channel absolute difference, averaged.
var totalDiff: UInt64 = 0
for i in 0..<count {
    let av = a[i]
    let bv = b[i]
    totalDiff += UInt64(av > bv ? av - bv : bv - av)
}
let mean = Double(totalDiff) / Double(count)

print(String(
    format: "baseline=%@ fresh=%@ mean_diff=%.4f threshold=%.4f",
    baselinePath, freshPath, mean, threshold
))

if mean > threshold {
    die("snapshot mismatch: mean per-channel difference \(mean) exceeds \(threshold)")
}
