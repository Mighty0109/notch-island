// 로고 산출물 렌더러 — scripts/logo-assets.sh 가 Sources/NotchIsland/Support/LogoImage.swift 와 함께 컴파일해 실행한다.
// 사용: render-logo-assets sheet <out.png> | icon <out-dir.iconset>
// 비교 시트: 후보 3개 × (라이트·다크 메뉴바 바탕, 실제 18pt @2x) + 8배 확대(@1x·@2x 픽셀 그대로 보이게 보간 없음).
import AppKit

/// 템플릿 이미지를 메뉴바가 하듯 단색으로 칠한 비트맵(scale 배).
func tinted(_ image: NSImage, scale: CGFloat, color: NSColor) -> NSBitmapImageRep {
    let px = Int(image.size.width * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    image.draw(in: CGRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
    color.setFill()
    CGRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func renderSheet(to url: URL) throws {
    let candidates = LogoImage.Candidate.allCases
    let light = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
    let dark = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1)
    let rowH: CGFloat = 200, colW: CGFloat = 420, header: CGFloat = 60
    let size = NSSize(width: colW * CGFloat(candidates.count), height: header + rowH * 2)
    let sheet = NSImage(size: size, flipped: true) { _ in
        NSColor.white.setFill(); CGRect(origin: .zero, size: size).fill()
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.black]
        let smallAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray]
        for (i, c) in candidates.enumerated() {
            let x0 = colW * CGFloat(i)
            let mark = c == LogoImage.current ? "  ← 적용" : ""
            (c.title + mark).draw(at: CGPoint(x: x0 + 16, y: 18), withAttributes: titleAttrs)
            let image = LogoImage.menuBarImage(c)
            for (row, (bg, tint, name)) in [(light, NSColor.black, "라이트"), (dark, NSColor.white, "다크")].enumerated() {
                let y0 = header + rowH * CGFloat(row)
                // 메뉴바 띠(실제 24pt 높이 @2x 로 그림) — 아이콘 18pt 를 세로 중앙에.
                let bar = CGRect(x: x0 + 16, y: y0 + 12, width: 120, height: 24)
                bg.setFill(); bar.fill()
                let rep2 = tinted(image, scale: 2, color: tint)
                rep2.draw(in: CGRect(x: bar.minX + 51, y: bar.minY + 3, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                "\(name) 메뉴바 · 실제 크기(@2x)".draw(at: CGPoint(x: bar.minX, y: bar.maxY + 4), withAttributes: smallAttrs)
                // 8배 확대 — @1x 와 @2x 픽셀을 보간 없이.
                for (k, scale) in [CGFloat(1), 2].enumerated() {
                    let rep = tinted(image, scale: scale, color: tint)
                    let box = CGRect(x: x0 + 160 + CGFloat(k) * 128, y: y0 + 12, width: 18 * 7, height: 18 * 7)
                    bg.setFill(); box.insetBy(dx: -8, dy: -8).fill()
                    NSGraphicsContext.current?.imageInterpolation = .none
                    rep.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
                    NSGraphicsContext.current?.imageInterpolation = .default
                    "@\(Int(scale))x 픽셀 ×7".draw(at: CGPoint(x: box.minX - 8, y: box.maxY + 12), withAttributes: smallAttrs)
                }
            }
        }
        return true
    }
    // 시트 자체는 @2x 로 저장.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    sheet.draw(in: CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// iconutil 이 먹는 .iconset 폴더(icon_16x16.png … icon_512x512@2x.png)를 채운다.
func renderIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let px = pt * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pt, height: pt)
        let image = NSImage(size: NSSize(width: pt, height: pt), flipped: true) { _ in
            LogoImage.drawAppIcon(side: CGFloat(pt)); return true
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: pt, height: pt))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write("usage: render-logo-assets sheet <out.png> | icon <out.iconset>\n".data(using: .utf8)!); exit(2) }
let out = URL(fileURLWithPath: args[2])
switch args[1] {
case "sheet": try renderSheet(to: out)
case "icon": try renderIconset(to: out)
default: exit(2)
}
print("WROTE: \(out.path)")
