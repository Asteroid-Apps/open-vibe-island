import AppKit
import PDFKit
import SwiftUI
import OpenIslandCore

/// T3's native icon union and dark-mode palette, rendered without a web view.
struct T3ProjectIconView: View {
    let projectName: String
    let icon: T3ProjectIcon?
    var imageData: Data?

    private var fallback: T3ProjectIcon { .fallback(projectName: projectName) }
    private var appearance: T3ProjectIcon { icon ?? fallback }
    private var tint: Color { T3ProjectIconAssets.color(named: appearance.color ?? fallback.color ?? "gray") }

    var body: some View {
        Group {
            if appearance.kind == "lucide", let name = appearance.name, let image = T3ProjectIconAssets.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(tint)
            } else if appearance.kind == "emoji", let emoji = appearance.emoji {
                Text(emoji).font(.system(size: 13)).lineLimit(1)
            } else if icon == nil, let imageData, let image = T3ProjectIconAssets.image(data: imageData) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                monogram
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.width / 4), with: .color(tint.opacity(0.14)))
            let letters = appearance.kind == "monogram" ? appearance.text ?? fallback.text ?? "PR" : fallback.text ?? "PR"
            let text = context.resolve(Text(letters).font(.system(size: size.height * 8.25 / 16, weight: .bold, design: .monospaced)).foregroundColor(tint))
            let measured = text.measure(in: CGSize(width: 100, height: 100))
            let targetWidth = size.width * (letters.count == 1 ? 6 : 12) / 16
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: targetWidth / max(1, measured.width), y: 1)
            context.draw(text, at: .zero, anchor: .center)
        }
    }
}

@MainActor
enum T3ProjectIconAssets {
    private static let vectorCache = NSCache<NSString, NSImage>()
    private static let imageCache = NSCache<NSData, NSImage>()
    private static let pages: [String: Int] = readJSON("t3-lucide-icons") ?? [:]
    private static let palette: [String: [Double]] = readJSON("t3-project-colors") ?? [:]
    private static let document: PDFDocument? = Bundle.appResources.url(forResource: "t3-lucide-icons", withExtension: "pdf").flatMap(PDFDocument.init(url:))

    private static func readJSON<T: Decodable>(_ name: String) -> T? {
        guard let url = Bundle.appResources.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func color(named name: String) -> Color {
        let rgb = palette[name] ?? palette["gray"] ?? [0.6, 0.6, 0.6]
        return Color(.sRGB, red: rgb[0], green: rgb[1], blue: rgb[2], opacity: 1)
    }

    static func image(named name: String) -> NSImage? {
        if let cached = vectorCache.object(forKey: name as NSString) { return cached }
        guard let index = pages[name], let data = document?.page(at: index)?.dataRepresentation,
              let image = NSImage(data: data) else { return nil }
        image.isTemplate = true
        vectorCache.setObject(image, forKey: name as NSString)
        return image
    }

    static func image(data: Data) -> NSImage? {
        if let cached = imageCache.object(forKey: data as NSData) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: data as NSData)
        return image
    }
}
