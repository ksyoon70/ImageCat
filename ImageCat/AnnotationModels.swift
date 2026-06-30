//
//  AnnotationModels.swift
//  ImageCat
//
//  Created by headway on 2026/06/30.
//

import Cocoa

struct LabelMeAnnotation: Decodable {
    var shapes: [Shape]
    var imageHeight: CGFloat
    var imageWidth: CGFloat

    var imageSize: NSSize {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        return NSSize(width: imageWidth, height: imageHeight)
    }

    struct Shape: Decodable {
        let label: String
        var points: [Point]
        let shapeType: String?

        enum CodingKeys: String, CodingKey {
            case label
            case points
            case shapeType = "shape_type"
        }
    }

    struct Point: Decodable {
        var x: CGFloat
        var y: CGFloat

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            x = CGFloat(try container.decode(Double.self))
            y = CGFloat(try container.decode(Double.self))
        }

        init(x: CGFloat, y: CGFloat) {
            self.x = x
            self.y = y
        }
    }
}

struct PolygonLabelRow {
    let shapeIndex: Int
    let label: String
    let color: NSColor
    var isVisible: Bool = true
}

enum LabelColorProvider {
    private static let palette: [NSColor] = [
        .systemGreen,
        .systemRed,
        .systemBlue,
        .systemOrange,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemYellow
    ]

    static func colors(for labels: [String]) -> [String: NSColor] {
        let uniqueLabels = Array(Set(labels)).sorted()

        return Dictionary(uniqueKeysWithValues: uniqueLabels.enumerated().map { index, label in
            (label, palette[index % palette.count])
        })
    }
}
