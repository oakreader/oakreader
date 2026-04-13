import Foundation
import AppKit

struct SignatureModel: Identifiable, Equatable {
    let id: UUID
    var type: SignatureType
    var imageData: Data?
    var name: String
    var dateCreated: Date

    enum SignatureType: Equatable {
        case drawn(points: [[CGPoint]])
        case typed(text: String, fontName: String)
        case image
    }

    init(drawn points: [[CGPoint]], name: String = "Signature") {
        self.id = UUID()
        self.type = .drawn(points: points)
        self.imageData = nil
        self.name = name
        self.dateCreated = Date()
    }

    init(typed text: String, fontName: String = "Snell Roundhand", name: String = "Signature") {
        self.id = UUID()
        self.type = .typed(text: text, fontName: fontName)
        self.imageData = nil
        self.name = name
        self.dateCreated = Date()
    }

    init(image: NSImage, name: String = "Signature") {
        self.id = UUID()
        self.type = .image
        self.imageData = image.tiffRepresentation
        self.name = name
        self.dateCreated = Date()
    }

    func renderToImage(size: CGSize = CGSize(width: 200, height: 60)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        switch type {
        case .drawn(let strokes):
            let path = NSBezierPath()
            path.lineWidth = 2.0
            NSColor.black.setStroke()
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                // Scale points to fit in image
                let scaleX = size.width / max(1, strokes.flatMap { $0 }.map(\.x).max() ?? 1)
                let scaleY = size.height / max(1, strokes.flatMap { $0 }.map(\.y).max() ?? 1)
                let scale = min(scaleX, scaleY) * 0.9
                path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
                for point in stroke.dropFirst() {
                    path.line(to: CGPoint(x: point.x * scale, y: point.y * scale))
                }
            }
            path.stroke()

        case .typed(let text, let fontName):
            let font = NSFont(name: fontName, size: min(size.height * 0.7, 36)) ?? NSFont.systemFont(ofSize: 24)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let str = text as NSString
            let textSize = str.size(withAttributes: attrs)
            let origin = CGPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2
            )
            str.draw(at: origin, withAttributes: attrs)

        case .image:
            if let data = imageData, let img = NSImage(data: data) {
                img.draw(in: CGRect(origin: .zero, size: size))
            }
        }

        image.unlockFocus()
        return image
    }
}
