import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// v2:源图已有透明背景(黑是预览器垫底)。深灰箭头实为 #131417(近 Carbon)。
// 逐像素:绿色通道 >40 判为 Lime,否则判为深灰箭头;深色主题箭头→纸白,
// 浅色主题箭头→墨色、Lime→C5D400。原 alpha 保留(边缘 AA 不破坏)。
// 用法:swift makelogo.swift <项目根>

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let inURL = URL(fileURLWithPath: "\(root)/design/assets/protosync-logo-concept-v1.png")
guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("无法读取源图") }

let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

let paper = (0.949, 0.953, 0.933)   // F2F3EE
let ink   = (0.082, 0.094, 0.106)   // 15181B
let limeL = (0.773, 0.831, 0.0)     // C5D400

var outDark = [UInt8](repeating: 0, count: w * h * 4)
var outLight = [UInt8](repeating: 0, count: w * h * 4)
for i in stride(from: 0, to: w * h * 4, by: 4) {
    let a = Double(px[i + 3]) / 255
    guard a > 0 else { continue }
    // 预乘缓冲:反预乘取真色
    let r = Double(px[i]) / a / 255, g = Double(px[i + 1]) / a / 255, b = Double(px[i + 2]) / a / 255
    let isLime = g > 40 / 255.0 && g > r && b < g * 0.6
    let d = isLime ? (r, g, b) : paper
    let l = isLime ? limeL : ink
    outDark[i] = UInt8(min(255, d.0 * 255 * a + 0.5))
    outDark[i + 1] = UInt8(min(255, d.1 * 255 * a + 0.5))
    outDark[i + 2] = UInt8(min(255, d.2 * 255 * a + 0.5))
    outDark[i + 3] = px[i + 3]
    outLight[i] = UInt8(min(255, l.0 * 255 * a + 0.5))
    outLight[i + 1] = UInt8(min(255, l.1 * 255 * a + 0.5))
    outLight[i + 2] = UInt8(min(255, l.2 * 255 * a + 0.5))
    outLight[i + 3] = px[i + 3]
}

func write(_ data: [UInt8], name: String) {
    let side = 320
    var scaled = [UInt8](repeating: 0, count: side * side * 4)
    let sctx = CGContext(data: &scaled, width: side, height: side, bitsPerComponent: 8,
                         bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sctx.interpolationQuality = .high
    var src2 = data
    guard let fctx = CGContext(data: &src2, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let fimg = fctx.makeImage() else { fatalError("重建失败") }
    sctx.draw(fimg, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let simg = sctx.makeImage() else { fatalError() }
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: "\(root)/\(name)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, simg, nil)
    CGImageDestinationFinalize(dest)
    print("✅ \(name)")
}

write(outDark, name: "design/assets/protosync-logo-dark.png")
write(outLight, name: "design/assets/protosync-logo-light.png")
