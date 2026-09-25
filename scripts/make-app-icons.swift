import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// 从 logo 概念稿生成三端应用图标:
//   iOS    Assets.xcassets/AppIcon(1024,Carbon 底 + 深色变体 logo)
//   Android res/mipmap-* 自适应图标(前景 = 深色变体 logo / 单色层,背景 = Carbon 950 纯色)
// 用法:swift make-app-icons.swift <项目根>

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let inURL = URL(fileURLWithPath: "\(root)/design/assets/protosync-logo-concept-v1.png")
guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("无法读取源图") }

let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx0 = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

// 深色变体重制(同 make-logo-assets.swift):箭头→纸白,Lime 保留
var dark = [UInt8](repeating: 0, count: w * h * 4)
var mono = [UInt8](repeating: 0, count: w * h * 4)   // 单色层(Android 13 主题图标)
for i in stride(from: 0, to: w * h * 4, by: 4) {
    let a = Double(px[i + 3]) / 255
    guard a > 0 else { continue }
    let r = Double(px[i]) / a / 255, g = Double(px[i + 1]) / a / 255, b = Double(px[i + 2]) / a / 255
    let isLime = g > 40 / 255.0 && g > r && b < g * 0.6
    let paper = (0.949, 0.953, 0.933)
    let d = isLime ? (r, g, b) : paper
    dark[i] = UInt8(min(255, d.0 * 255 * a + 0.5))
    dark[i + 1] = UInt8(min(255, d.1 * 255 * a + 0.5))
    dark[i + 2] = UInt8(min(255, d.2 * 255 * a + 0.5))
    dark[i + 3] = px[i + 3]
    mono[i] = 255; mono[i + 1] = 255; mono[i + 2] = 255; mono[i + 3] = px[i + 3]
}

// 用重上色缓冲生成 CGImage
func imageFrom(_ buffer: [UInt8]) -> CGImage? {
    var b = buffer
    let ctx = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    return ctx?.makeImage()
}

func compose(size: Int, fraction: CGFloat, bg: (CGFloat, CGFloat, CGFloat)?, logo: CGImage) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let bg {
        ctx.setFillColor(red: bg.0, green: bg.1, blue: bg.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    let logoSize = CGFloat(size) * fraction
    let origin = (CGFloat(size) - logoSize) / 2
    ctx.interpolationQuality = .high
    ctx.draw(logo, in: CGRect(x: origin, y: origin, width: logoSize, height: logoSize))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("无法创建 \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("写出失败 \(path)") }
    print("✅ \(path)")
}

func writeText(_ text: String, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    print("✅ \(path)")
}

let logo = imageFrom(dark)!
let monoLogo = imageFrom(mono)!
let carbon950 = (CGFloat(0x08) / 255, CGFloat(0x0A) / 255, CGFloat(0x0C) / 255)

// ---------- iOS ----------
let iosIcon = compose(size: 1024, fraction: 0.70, bg: carbon950, logo: logo)
writePNG(iosIcon, to: "\(root)/ios/ProtoSync/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
writeText("""
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: "\(root)/ios/ProtoSync/Assets.xcassets/AppIcon.appiconset/Contents.json")
writeText("""
{
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: "\(root)/ios/ProtoSync/Assets.xcassets/Contents.json")

// ---------- Android 自适应图标 ----------
// 前景内容须落在中央 ~66dp/108dp 安全区 → logo 占画布 58%
let densities: [(String, Int)] = [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)]
for (dpi, size) in densities {
    writePNG(compose(size: size, fraction: 0.58, bg: nil, logo: logo),
             to: "\(root)/android/res/mipmap-\(dpi)/ic_launcher_foreground.png")
    writePNG(compose(size: size, fraction: 0.58, bg: nil, logo: monoLogo),
             to: "\(root)/android/res/mipmap-\(dpi)/ic_launcher_monochrome.png")
}

let adaptiveXML = """
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
"""
writeText(adaptiveXML, to: "\(root)/android/res/mipmap-anydpi-v26/ic_launcher.xml")
writeText(adaptiveXML, to: "\(root)/android/res/mipmap-anydpi-v26/ic_launcher_round.xml")
writeText("""
<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <solid android:color="#080A0C" />
</shape>
""", to: "\(root)/android/res/drawable/ic_launcher_background.xml")

print("\n三端图标生成完毕")
