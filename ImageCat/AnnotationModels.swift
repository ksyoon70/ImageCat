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

    // JSON이 없는 이미지에도 새 라벨을 추가할 수 있도록 빈 annotation을 코드에서 만든다.
    init(shapes: [Shape], imageHeight: CGFloat, imageWidth: CGFloat) {
        self.shapes = shapes
        self.imageHeight = imageHeight
        self.imageWidth = imageWidth
    }

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

        // create 모드에서 polygon/rectangle shape를 새로 추가할 때 사용한다.
        init(label: String, points: [Point], shapeType: String?) {
            self.label = label
            self.points = points
            self.shapeType = shapeType
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

// 폴더 전체 JSON에서 수집한 label과 palette index의 쌍이다.
// NSColor 자체보다 index를 저장해야 Set/Hashable로 안정적으로 다룰 수 있다.
struct LabelColorPair: Hashable {
    let label: String
    let colorIndex: Int

    var color: NSColor {
        return LabelColorProvider.color(at: colorIndex)
    }
}

enum LabelColorProvider {
    // 오늘 수정: labelme/imgviz와 같은 256색 label colormap을 쓰기 위한 색상 개수다.
    private static let labelmeColorCount = 256

    static func color(at index: Int) -> NSColor {
        // 오늘 수정: labelme auto 색상은 0번 검정색을 건너뛰므로 index 0을 label id 1에 매핑한다.
        let labelmeLabelID = (index + 1) % labelmeColorCount
        let rgb = labelmeRGB(for: labelmeLabelID)
        return NSColor(
            calibratedRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }

    // 폴더 단위로 같은 label은 항상 같은 색을 쓰도록 정렬된 label 목록에서 pair set을 만든다.
    static func colorPairs(for labels: [String]) -> Set<LabelColorPair> {
        let uniqueLabels = Array(Set(labels)).sorted()
        return Set(uniqueLabels.enumerated().map { index, label in
            // 오늘 수정: 8색 palette 반복이 아니라 labelme colormap index를 그대로 보관한다.
            LabelColorPair(label: label, colorIndex: index)
        })
    }

    static func extending(
        _ pairs: Set<LabelColorPair>,
        with labels: [String]
    ) -> Set<LabelColorPair> {
        let existingLabels = Set(pairs.map { $0.label })
        let combinedLabels = Array(existingLabels.union(labels)).sorted()
        var extendedPairs = pairs

        for label in labels where !existingLabels.contains(label) {
            guard let index = combinedLabels.firstIndex(of: label) else { continue }
            // 오늘 수정: 새 label도 기존 label들과 같은 정렬 위치를 기준으로 labelme 색을 받는다.
            extendedPairs.insert(LabelColorPair(label: label, colorIndex: index))
        }

        return extendedPairs
    }

    // 폴더에서 미리 계산한 색상 pair를 우선하고, 새 label은 같은 정렬 규칙으로 보충한다.
    static func colors(
        for labels: [String],
        preferredPairs: Set<LabelColorPair> = []
    ) -> [String: NSColor] {
        let uniqueLabels = Array(Set(labels)).sorted()
        let preferredLabels = Set(preferredPairs.map { $0.label })
        let combinedLabels = Array(preferredLabels.union(uniqueLabels)).sorted()
        let fallbackPairs = colorPairs(for: combinedLabels)
        let mergedPairs = fallbackPairs.filter { !preferredLabels.contains($0.label) }.union(preferredPairs)

        return Dictionary(uniqueKeysWithValues: mergedPairs.map { pair in
            (pair.label, pair.color)
        })
    }

    // labelme는 imgviz.label_colormap()의 0번 검정색을 건너뛴 색을 shape 색상으로 쓴다.
    private static func labelmeRGB(for labelID: Int) -> (red: Int, green: Int, blue: Int) {
        var red = 0
        var green = 0
        var blue = 0

        for bit in 0..<8 {
            let shift = 7 - bit
            red |= bitValue(labelID >> (bit * 3), at: 0) << shift
            green |= bitValue(labelID >> (bit * 3), at: 1) << shift
            blue |= bitValue(labelID >> (bit * 3), at: 2) << shift
        }

        return (red, green, blue)
    }

    private static func bitValue(_ value: Int, at index: Int) -> Int {
        // 오늘 수정: imgviz의 bitget 동작을 Swift 정수 비트 연산으로 옮긴 helper다.
        return (value >> index) & 1
    }
}
