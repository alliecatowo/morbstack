import CoreGraphics
import ImageIO
import Foundation

// crop-top.swift <input.png> <width> <height> <output.png>
// Crops the top-left width x height region out of input.png. Written
// because `sips -c H W --cropOffset Y X` was empirically found to ignore
// small offset values on this machine (sips-316) and silently fall back to
// a centered crop instead of a top-left one -- confirmed by round-tripping
// known pixel values through it. CoreGraphics does exactly what it's told.

let args = CommandLine.arguments
guard args.count == 5,
      let width = Int(args[2]), let height = Int(args[3]) else {
    FileHandle.standardError.write("usage: crop-top.swift <in.png> <width> <height> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let inputPath = args[1]
let outputPath = args[4]

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("error: could not read \(inputPath)\n".data(using: .utf8)!)
    exit(1)
}

// Empirically, (0,0) here is the top-left of the *decoded* image regardless
// of the on-disk PNG's scanline order or CGImage's usual bottom-left-origin
// convention for drawing contexts: ImageIO normalizes that when it decodes
// the source, and CGImage.cropping(to:) crops in that same already-normalized
// space. Verified by round-tripping known per-row pixel values through this
// exact call before trusting it (see packaging/render-dmg-background.sh).
let cropRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
guard let cropped = image.cropping(to: cropRect) else {
    FileHandle.standardError.write("error: crop rect \(cropRect) out of bounds for \(image.width)x\(image.height)\n".data(using: .utf8)!)
    exit(1)
}

guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("error: could not open \(outputPath) for writing\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, cropped, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("error: failed to write \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}
print("wrote \(outputPath) (\(width)x\(height))")
