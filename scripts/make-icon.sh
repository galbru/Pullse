#!/bin/sh
# Render docs/logo.svg into an .icns: macOS app icons sit on a 1024 canvas with the
# rounded square inset to 824, so the mark is drawn into that inner square at each size.
# AppKit reads SVG, so this needs nothing beyond the Command Line Tools.
# Usage: scripts/make-icon.sh <out.icns>
set -eu
# Resolve the output against the caller's directory before moving to the repo root.
case "$1" in
    /*) OUT="$1" ;;
    *) OUT="$PWD/$1" ;;
esac
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

swift - docs/logo.svg "$SET" <<'SWIFT'
import AppKit
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}
let args = CommandLine.arguments
guard let logo = NSImage(contentsOfFile: args[1]) else { fail("can't read \(args[1])") }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fail("can't make a \(px) px bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let inset = CGFloat(px) * 100 / 1024
        logo.draw(in: NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("can't render \(args[1]) at \(px) px")
        }
        do {
            try png.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
        } catch {
            fail("can't write \(name): \(error.localizedDescription)")
        }
    }
}
SWIFT

iconutil -c icns "$SET" -o "$OUT"
