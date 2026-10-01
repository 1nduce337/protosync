import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// 从 logo 概念稿生成各端图标:
//   iOS    Assets.xcassets/AppIcon(1024,Carbon 底 + 深色变体 logo)
//   Android res/mipmap-* 自适应图标(前景 = 深色变体 logo / 单色层,背景 = Carbon 950 纯色)
//   macOS  packaging/macos/AppIcon.iconset(make-app.sh 打包成 icns)+ 菜单栏模板图标 MenuBarIcon(@2x).png
// 用法:swift make-app-icons.swift <项目根>

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let inURL = URL(fileURLWithPath: "\(root)/docs/design/assets/protosync-logo-concept-v1.png")
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

// ---------- macOS ----------
// 1) 应用图标:Big Sur 网格(1024 画布中央 824 圆角方块,四周留给阴影),Carbon 底 + 深色变体 logo。
//    输出 iconset,make-app.sh 用 iconutil 打包成 AppIcon.icns。
func macIcon(size: Int, logo: CGImage) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.024,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(path)
    ctx.setFillColor(red: CGFloat(0x11) / 255, green: CGFloat(0x14) / 255, blue: CGFloat(0x17) / 255, alpha: 1)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    let logoSize = body.width * 0.74   // 源图自带留白,与 iOS(画布 70%)视觉大小一致
    ctx.draw(logo, in: CGRect(x: body.midX - logoSize / 2, y: body.midY - logoSize / 2,
                              width: logoSize, height: logoSize))
    return ctx.makeImage()!
}

let iconset: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in iconset {
    writePNG(macIcon(size: size, logo: logo), to: "\(root)/packaging/macos/AppIcon.iconset/\(name).png")
}

// 2) 菜单栏模板图标:logo 剪影(只用 alpha,系统按菜单栏深浅自动着色),裁到图形边界后
//    等比放进 18pt 方框(@1x 18px / @2x 36px)。位图内存首行即图像顶行,与 CGImage.cropping 坐标一致。
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where px[(y * w + x) * 4 + 3] > 24 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, let monoCropped = monoLogo.cropping(to: CGRect(x: minX, y: minY,
                                                                  width: maxX - minX + 1, height: maxY - minY + 1))
else { fatalError("logo 没有不透明像素") }

func templateIcon(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let box = CGFloat(size) * 0.9
    let aspect = CGFloat(monoCropped.width) / CGFloat(monoCropped.height)
    let drawW = aspect >= 1 ? box : box * aspect
    let drawH = aspect >= 1 ? box / aspect : box
    ctx.draw(monoCropped, in: CGRect(x: (CGFloat(size) - drawW) / 2, y: (CGFloat(size) - drawH) / 2,
                                     width: drawW, height: drawH))
    return ctx.makeImage()!
}
writePNG(templateIcon(size: 18), to: "\(root)/Sources/ProtoSyncApp/Resources/MenuBarIcon.png")
writePNG(templateIcon(size: 36), to: "\(root)/Sources/ProtoSyncApp/Resources/MenuBarIcon@2x.png")

print("\n各端图标生成完毕(iOS / Android / macOS 应用图标与菜单栏图标)")
