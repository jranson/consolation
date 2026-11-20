#!/usr/bin/env swift
// Generates the app icons from the two vector sources in assets/ (Pixelmator Pro SVG exports):
//
//   assets/app-icon-background-large.svg   the gradient (the one visible layer is used)
//   assets/app-icon-foreground.svg         the white television (visible layers only)
//
// macOS, iOS and iPadOS use an Icon Composer document, which the system renders at every size:
//
//   Consolation/AppIcon.icon               icon.json plus Assets/foreground.svg. The fill and the SVG are rewritten on
//                                          every run; anything else set in Icon Composer (glass, shadow, position) is
//                                          kept.
//
// tvOS uses a layered (parallax) image stack, drawn from the vectors at each pixel size:
//
//   Consolation/Assets.xcassets/App Icon & Top Shelf Image.brandassets
//
// Usage, from the repository root (or `make generate-appicons`, which also renders the docs PNGs):
//   swift scripts/generate-app-icons.swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error, CustomStringConvertible {
    let description: String
}

let backgroundSource = "assets/app-icon-background-large.svg"
let foregroundSource = "assets/app-icon-foreground.svg"
let iconDocument = "Consolation/AppIcon.icon"
let brandAssets = "Consolation/Assets.xcassets/App Icon & Top Shelf Image.brandassets"
/// The group that holds what is shown on the television's screen; it becomes the front parallax layer on tvOS.
let screenGlyphID = "app-icon-screen-glyph"
/// Icon Composer: the foreground's scale and downward shift (negative is up) on the 1024 canvas, used when the
/// document is first created. They keep the television clear of the edges and the antenna tips inside the corners.
let iconForegroundScale = 0.82
let iconForegroundOffset = -6.0
/// tvOS: the side of the (square) foreground as a fraction of the image's height. Layers grow and shift as the icon
/// is focused, so the television stays well inside the edges.
let tvForegroundFraction = 0.86
let topShelfForegroundFraction = 0.8

// MARK: - SVG

extension XMLElement {
    var childElements: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    var identifier: String? { attribute(forName: "id")?.stringValue }
    var isHidden: Bool { attribute(forName: "visibility")?.stringValue == "hidden" }
    var isGradient: Bool { name == "linearGradient" || name == "radialGradient" }

    func descendant(withID wanted: String) -> XMLElement? {
        if identifier == wanted { return self }
        return childElements.lazy.compactMap { $0.descendant(withID: wanted) }.first
    }

    func isInside(elementWithID wanted: String) -> Bool {
        var node: XMLNode? = self
        while let element = node as? XMLElement {
            if element.identifier == wanted { return true }
            node = element.parent
        }
        return false
    }

    /// Removes every descendant that `drop` matches, then the groups that are left empty.
    func prune(_ drop: (XMLElement) -> Bool) {
        for child in childElements {
            if drop(child) {
                removeChild(at: child.index)
                continue
            }
            child.prune(drop)
            if child.name == "g", child.childElements.isEmpty { removeChild(at: child.index) }
        }
    }

    func collectPaintReferences(into found: inout Set<String>) {
        for name in ["fill", "stroke"] {
            guard let value = attribute(forName: name)?.stringValue, value.hasPrefix("url(#") else { continue }
            found.insert(String(value.dropFirst(5).dropLast()))
        }
        childElements.forEach { $0.collectPaintReferences(into: &found) }
    }
}

/// The visible part of an SVG file: hidden layers, anything `drop` matches and unused gradients are removed.
func visibleSVG(at path: String, dropping drop: (XMLElement) -> Bool = { _ in false }) throws -> XMLDocument {
    let document = try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodePreserveWhitespace])
    guard let root = document.rootElement() else { throw Failure(description: "\(path): not an SVG document") }
    root.prune { $0.isHidden || (!$0.isGradient && drop($0)) }
    var used = Set<String>()
    root.collectPaintReferences(into: &used)
    root.prune { $0.isGradient && !used.contains($0.identifier ?? "") }
    for child in document.children ?? [] where child.kind == .comment { document.removeChild(at: child.index) }
    guard root.childElements.contains(where: { !$0.isGradient }) else {
        throw Failure(description: "\(path): no visible layers")
    }
    return document
}

func image(from document: XMLDocument) throws -> NSImage {
    guard let image = NSImage(data: document.xmlData) else { throw Failure(description: "can't render an SVG layer") }
    return image
}

// MARK: - Gradient

func iconColor(hex: String) throws -> String {
    guard hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else {
        throw Failure(description: "unsupported gradient color \(hex)")
    }
    let parts = [value >> 16, (value >> 8) & 0xFF, value & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
    return "srgb:" + parts.joined(separator: ",") + ",1.00000"
}

/// The background's two-color vertical gradient as Icon Composer takes it: the top color, then the bottom one.
func gradientColors(of document: XMLDocument) throws -> [String] {
    var used = Set<String>()
    document.rootElement()?.collectPaintReferences(into: &used)
    guard let gradientID = used.first, used.count == 1,
          let gradient = document.rootElement()?.descendant(withID: gradientID), gradient.name == "linearGradient"
    else { throw Failure(description: "\(backgroundSource): expected one visible layer filled with a linear gradient") }
    let stops = gradient.childElements.filter { $0.name == "stop" }
    guard let first = stops.first, let last = stops.last, stops.count >= 2 else {
        throw Failure(description: "\(backgroundSource): the gradient needs two stops")
    }
    func coordinate(_ name: String) -> Double { Double(gradient.attribute(forName: name)?.stringValue ?? "") ?? 0 }
    guard abs(coordinate("x1") - coordinate("x2")) < 1, coordinate("y1") != coordinate("y2") else {
        throw Failure(description: "\(backgroundSource): only a vertical gradient is supported")
    }
    let topFirst = coordinate("y1") < coordinate("y2") ? [first, last] : [last, first]
    return try topFirst.map { try iconColor(hex: $0.attribute(forName: "stop-color")?.stringValue ?? "") }
}

// MARK: - Output

func writeJSON(_ object: Any, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: url)
}

struct Layer {
    var image: NSImage
    /// The side of the centered square the image is drawn in, as a fraction of the canvas height; nil fills the canvas.
    var squareFraction: Double?
}

func writePNG(_ layers: [Layer], width: Int, height: Int, to path: String) throws {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { throw Failure(description: "can't create a \(width)x\(height) bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for layer in layers {
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let fraction = layer.squareFraction {
            let side = Double(height) * fraction
            rect = CGRect(x: (Double(width) - side) / 2, y: (Double(height) - side) / 2, width: side, height: side)
        }
        layer.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(description: "can't write \(path)") }
    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure(description: "can't write \(path)") }
}

let catalogInfo: [String: Any] = ["author": "xcode", "version": 1]

/// Writes an image set with one PNG per scale and returns nothing; `base` is the 1x size in points.
func writeImageSet(_ layers: [Layer], base: (width: Int, height: Int), scales: [Int], to directory: String) throws {
    var images: [[String: Any]] = []
    for scale in scales {
        let filename = scale == 1 ? "image.png" : "image@\(scale)x.png"
        try writePNG(layers, width: base.width * scale, height: base.height * scale, to: "\(directory)/\(filename)")
        images.append(["filename": filename, "idiom": "tv", "scale": "\(scale)x"])
    }
    try writeJSON(["images": images, "info": catalogInfo], to: "\(directory)/Contents.json")
}

/// Writes a parallax image stack; `layers` are named and ordered front to back.
func writeImageStack(
    _ layers: [(name: String, layer: Layer)], base: (width: Int, height: Int), scales: [Int], to directory: String
) throws {
    for (name, layer) in layers {
        let layerDirectory = "\(directory)/\(name).imagestacklayer"
        try writeJSON(["info": catalogInfo], to: "\(layerDirectory)/Contents.json")
        try writeImageSet([layer], base: base, scales: scales, to: "\(layerDirectory)/Content.imageset")
    }
    let entries = layers.map { ["filename": "\($0.name).imagestacklayer"] }
    try writeJSON(["info": catalogInfo, "layers": entries], to: "\(directory)/Contents.json")
}

// MARK: - Icon Composer document (macOS, iOS, iPadOS)

func writeIconDocument(background: XMLDocument, foreground: XMLDocument) throws {
    let colors = try gradientColors(of: background)
    let assetName = "foreground.svg"
    let assets = URL(fileURLWithPath: "\(iconDocument)/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try foreground.xmlData(options: [.nodePrettyPrint]).write(to: assets.appendingPathComponent(assetName))

    let jsonPath = "\(iconDocument)/icon.json"
    var icon: [String: Any] = [
        "groups": [[
            "layers": [[
                "glass": true,
                "image-name": assetName,
                "name": "television",
                "position": ["scale": iconForegroundScale, "translation-in-points": [0, iconForegroundOffset]]
            ]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": false, "value": 0.5]
        ]],
        "supported-platforms": ["squares": "shared"]
    ]
    if let data = FileManager.default.contents(atPath: jsonPath),
       let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        icon = existing
    }
    icon["fill"] = ["linear-gradient": colors]
    try writeJSON(icon, to: jsonPath)
    print("Wrote \(iconDocument)")
}

// MARK: - Layered image stack (tvOS)

func writeBrandAssets(background: XMLDocument, foreground: XMLDocument) throws {
    let back = Layer(image: try image(from: background), squareFraction: nil)
    let whole = try image(from: foreground)
    var stack: [(name: String, layer: Layer)] = [("Back", back)]
    if foreground.rootElement()?.descendant(withID: screenGlyphID) != nil {
        // Three layers: the screen's glyph floats in front of the television.
        let glyph = try visibleSVG(at: foregroundSource) { element in
            element.descendant(withID: screenGlyphID) == nil && !element.isInside(elementWithID: screenGlyphID)
        }
        let cabinet = try visibleSVG(at: foregroundSource) { $0.identifier == screenGlyphID }
        stack.insert(("Middle", Layer(image: try image(from: cabinet), squareFraction: tvForegroundFraction)), at: 0)
        stack.insert(("Front", Layer(image: try image(from: glyph), squareFraction: tvForegroundFraction)), at: 0)
    } else {
        stack.insert(("Front", Layer(image: whole, squareFraction: tvForegroundFraction)), at: 0)
    }

    try? FileManager.default.removeItem(atPath: brandAssets)
    let parts: [(name: String, role: String, width: Int, height: Int, scales: [Int], isStack: Bool)] = [
        ("App Icon - App Store.imagestack", "primary-app-icon", 1280, 768, [1], true),
        ("App Icon.imagestack", "primary-app-icon", 400, 240, [1, 2], true),
        ("Top Shelf Image Wide.imageset", "top-shelf-image-wide", 2320, 720, [1, 2], false),
        ("Top Shelf Image.imageset", "top-shelf-image", 1920, 720, [1, 2], false)
    ]
    let topShelf = [back, Layer(image: whole, squareFraction: topShelfForegroundFraction)]
    for part in parts {
        let directory = "\(brandAssets)/\(part.name)"
        let base = (width: part.width, height: part.height)
        if part.isStack {
            try writeImageStack(stack, base: base, scales: part.scales, to: directory)
        } else {
            try writeImageSet(topShelf, base: base, scales: part.scales, to: directory)
        }
    }
    let entries = parts.map { part -> [String: Any] in
        ["filename": part.name, "idiom": "tv", "role": part.role, "size": "\(part.width)x\(part.height)"]
    }
    try writeJSON(["assets": entries, "info": catalogInfo], to: "\(brandAssets)/Contents.json")
    print("Wrote \(brandAssets) (\(stack.count) layers)")
}

do {
    let background = try visibleSVG(at: backgroundSource)
    let foreground = try visibleSVG(at: foregroundSource)
    try writeIconDocument(background: background, foreground: foreground)
    try writeBrandAssets(background: background, foreground: foreground)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
