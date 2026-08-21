#!/usr/bin/env swift

import AppKit

let imagePath = CommandLine.arguments.dropFirst().first
    ?? "Resources/DMG/dmg-background.jpeg"
guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)),
      let bitmap = NSBitmapImageRep(data: imageData) else {
    fputs("Could not read DMG background: \(imagePath)\n", stderr)
    exit(1)
}

let nominalCanvasSize = NSSize(width: 600, height: 380)
let scaleX = CGFloat(bitmap.pixelsWide) / nominalCanvasSize.width
let scaleY = CGFloat(bitmap.pixelsHigh) / nominalCanvasSize.height
let nominalLabelRegions = [
    NSRect(x: 88, y: 108, width: 134, height: 42),
    NSRect(x: 378, y: 108, width: 134, height: 42)
]
let labelRegions = nominalLabelRegions.map { region in
    NSRect(
        x: region.minX * scaleX,
        y: region.minY * scaleY,
        width: region.width * scaleX,
        height: region.height * scaleY
    )
}

for (index, region) in labelRegions.enumerated() {
    var luminanceTotal = 0.0
    var sampleCount = 0
    for x in stride(from: Int(region.minX), to: Int(region.maxX), by: 2) {
        for y in stride(from: Int(region.minY), to: Int(region.maxY), by: 2) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let red = Double(color.redComponent)
            let green = Double(color.greenComponent)
            let blue = Double(color.blueComponent)
            luminanceTotal += 0.2126 * red + 0.7152 * green + 0.0722 * blue
            sampleCount += 1
        }
    }

    let averageLuminance = sampleCount > 0 ? luminanceTotal / Double(sampleCount) : 0
    guard averageLuminance >= 0.55 else {
        fputs(
            "Finder label region \(index + 1) is too dark: \(averageLuminance)\n",
            stderr
        )
        exit(1)
    }
}

print("DMG Finder label backgrounds have sufficient contrast")
