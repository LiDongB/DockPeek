#!/usr/bin/env swift
//
// make-icon.swift —— 用 CoreGraphics 绘制 DockPeek 的 App 图标
//
// 用法:
//   swift make-icon.swift <输出目录>
//
// 产物:
//   <输出目录>/AppIcon.iconset/icon_*.png  （1x + @2x 共 14 个尺寸）
//
// 设计:
//   macOS 风格的圆角方块（squircle-ish，圆角半径 ≈ 边长的 22%），
//   蓝色 → 靛蓝的垂直渐变；内部三块半透明白色的「窗口」圆角矩形，
//   一后两前、略微错位，像一叠窗口预览。刻意不加细节，保证 16px 下依然清晰。
//
import Foundation
import CoreGraphics
import ImageIO

// ---------------------------------------------------------------------------
// 设计稿以 1024x1024 为基准，其它尺寸按比例缩放
// ---------------------------------------------------------------------------
let designCanvas: CGFloat = 1024.0

// 圆角方块本体（留出一点外边距，更像原生 macOS 图标）
let bodyInset: CGFloat = 84.0
let bodyRect = CGRect(
    x: bodyInset,
    y: bodyInset,
    width: designCanvas - bodyInset * 2,
    height: designCanvas - bodyInset * 2
)
let bodySide = bodyRect.width
// 圆角半径 ≈ 边长的 22%
let bodyRadius = bodySide * 0.22

// 渐变色: 顶部蓝色 -> 底部靛蓝
let gradientTop = CGColor(red: 0.231, green: 0.510, blue: 0.965, alpha: 1.0)   // #3B82F6
let gradientBottom = CGColor(red: 0.310, green: 0.275, blue: 0.898, alpha: 1.0) // #4F46E5

/// 把「相对本体的单位矩形」换算成设计稿坐标
func unitRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    return CGRect(
        x: bodyRect.minX + bodyRect.width * x,
        y: bodyRect.minY + bodyRect.height * y,
        width: bodyRect.width * w,
        height: bodyRect.height * h
    )
}

// 后面的窗口（较大），前面的两张（较小、略微错位）
let backCard = unitRect(x: 0.14, y: 0.40, w: 0.72, h: 0.48)
let frontLeftCard = unitRect(x: 0.06, y: 0.10, w: 0.46, h: 0.40)
let frontRightCard = unitRect(x: 0.48, y: 0.16, w: 0.46, h: 0.40)
let cardRadius = bodySide * 0.058

/// 绘制一张半透明白色圆角「窗口」卡片
func drawCard(
    in ctx: CGContext,
    rect: CGRect,
    radius: CGFloat,
    fillAlpha: CGFloat,
    strokeAlpha: CGFloat,
    lineWidth: CGFloat
) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: fillAlpha))
    ctx.fillPath()

    // lineWidth <= 0 表示该尺寸下不描边（见 renderIcon 中的说明）
    guard lineWidth > 0 else { return }

    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: strokeAlpha))
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
}

/// 按指定像素尺寸渲染图标
func renderIcon(pixelSize: Int) throws -> CGImage {
    let size = CGFloat(pixelSize)
    // 设计稿坐标 -> 像素坐标的缩放系数
    let k = size / designCanvas

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw IconError.contextCreationFailed(pixelSize)
    }

    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // --- 1. 圆角方块 + 垂直渐变 -------------------------------------------
    let bodyPath = CGPath(
        roundedRect: bodyRect.applying(CGAffineTransform(scaleX: k, y: k)),
        cornerWidth: bodyRadius * k,
        cornerHeight: bodyRadius * k,
        transform: nil
    )

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [gradientTop, gradientBottom] as CFArray,
        locations: [0.0, 1.0]
    ) {
        // CGContext 原点在左下角：起点在上方 -> 蓝色在上，靛蓝在下
        let top = CGPoint(x: size / 2, y: size)
        let bottom = CGPoint(x: size / 2, y: 0)
        ctx.drawLinearGradient(gradient, start: top, end: bottom, options: [])
    } else {
        ctx.setFillColor(gradientTop)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    ctx.restoreGState()

    // --- 2. 三张窗口卡片（裁剪在本体内部） --------------------------------
    // 线宽按设备像素计算，保证最小 1px。
    // 例外：16px 下每张卡片只有 5~6 像素，描边会糊成一团网格，
    //       因此该尺寸直接不描边，只靠明暗层次区分层次 —— 保证小尺寸清晰。
    let lineWidth: CGFloat = pixelSize <= 16 ? 0.0 : max(1.0, 8.0 * k)
    // 小尺寸下把前后层次拉开一些，弥补没有描边的损失
    let backFill: CGFloat = pixelSize <= 16 ? 0.16 : 0.20
    let frontFill: CGFloat = pixelSize <= 16 ? 0.62 : 0.55

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()

    // 后面的大窗口：更淡、描边更弱，形成层次
    // （描边刻意压低，避免透过前排卡片的半透明填充形成干扰线）
    drawCard(
        in: ctx,
        rect: backCard.applying(CGAffineTransform(scaleX: k, y: k)),
        radius: cardRadius * k,
        fillAlpha: backFill,
        strokeAlpha: 0.30,
        lineWidth: lineWidth
    )
    // 前面两张小窗口：更亮、填充更实，明确压住后排卡片
    for rect in [frontLeftCard, frontRightCard] {
        drawCard(
            in: ctx,
            rect: rect.applying(CGAffineTransform(scaleX: k, y: k)),
            radius: cardRadius * k,
            fillAlpha: frontFill,
            strokeAlpha: 0.95,
            lineWidth: lineWidth
        )
    }
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        throw IconError.imageCreationFailed(pixelSize)
    }
    return image
}

enum IconError: Error, CustomStringConvertible {
    case contextCreationFailed(Int)
    case imageCreationFailed(Int)
    case destinationCreationFailed(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .contextCreationFailed(let s): return "无法创建 \(s)x\(s) 的 CGContext"
        case .imageCreationFailed(let s): return "无法生成 \(s)x\(s) 的 CGImage"
        case .destinationCreationFailed(let p): return "无法创建 PNG 写入目标: \(p)"
        case .writeFailed(let p): return "PNG 写入失败: \(p)"
        }
    }
}

/// 写出单个 PNG
func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        throw IconError.destinationCreationFailed(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.writeFailed(url.path)
    }
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        "用法: swift make-icon.swift <输出目录>\n".data(using: .utf8)!
    )
    exit(1)
}

let outputDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)

do {
    try FileManager.default.createDirectory(
        at: iconsetDir,
        withIntermediateDirectories: true,
        attributes: nil
    )
} catch {
    FileHandle.standardError.write(
        "❌ 无法创建目录 \(iconsetDir.path): \(error)\n".data(using: .utf8)!
    )
    exit(1)
}

// 基准尺寸 + 各自的 @2x
let baseSizes = [16, 32, 64, 128, 256, 512, 1024]

// 每个像素尺寸只渲染一次，多个文件名可复用同一张图
var cache: [Int: CGImage] = [:]
var written: [(name: String, pixels: Int)] = []

do {
    for base in baseSizes {
        for scale in 1...2 {
            let pixels = base * scale
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(base)x\(base)\(suffix).png"
            let url = iconsetDir.appendingPathComponent(name)

            let image: CGImage
            if let cached = cache[pixels] {
                image = cached
            } else {
                image = try renderIcon(pixelSize: pixels)
                cache[pixels] = image
            }

            try writePNG(image, to: url)
            written.append((name: name, pixels: pixels))
        }
    }
} catch {
    FileHandle.standardError.write("❌ 生成图标失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}

print("✅ 图标已生成到: \(iconsetDir.path)")
for item in written {
    print("   \(item.name)  (\(item.pixels)x\(item.pixels) px)")
}
print("共 \(written.count) 个 PNG 文件。")
