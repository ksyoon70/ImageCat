import Cocoa

@IBDesignable
final class ImageCurveControl: NSView {
    typealias CurveChangedHandler = (ImageCurveControl) -> Void

    var onCurveChanged: CurveChangedHandler?
    var onCurveEditingEnded: CurveChangedHandler?

    @IBInspectable var gridColor: NSColor = .gridColor { didSet { needsDisplay = true } }
    @IBInspectable var borderColor: NSColor = .black { didSet { needsDisplay = true } }
    @IBInspectable var curveColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    @IBInspectable var pointColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    @IBInspectable var selectionRadius: CGFloat = 12
    @IBInspectable var controlPointRadius: CGFloat = 5 { didSet { needsDisplay = true } }

    private(set) var lut: [UInt8] = (0...255).map { UInt8($0) }

    private var points: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 255, y: 255)
    ] {
        didSet {
            rebuildLUT()
            needsDisplay = true
        }
    }

    private var isEditing = false
    private var selectedPointIndex: Int?
    private var virtualPoint: CGPoint?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        rebuildLUT()
    }

    // 오늘 수정: reset 버튼에서 호출할 때는 preview를 원본 상태로 다시 렌더링해야 하므로 handler를 호출한다.
    // 반면 이미지 파일 선택 시에는 preview가 이미 새 원본 이미지를 직접 로드하므로,
    // notifiesChangeHandlers를 false로 넘겨 curve UI/LUT만 초기화하고 중복 렌더링을 피한다.
    func resetPoints(notifiesChangeHandlers: Bool = true) {
        selectedPointIndex = nil
        virtualPoint = nil
        isEditing = false
        points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 255, y: 255)
        ]
        // 오늘 수정: 조용한 reset 경로에서는 onCurveChanged/onCurveEditingEnded callback을 호출하지 않는다.
        guard notifiesChangeHandlers else { return }
        onCurveChanged?(self)
        // 리셋 버튼도 편집 종료와 같은 경로로 미리보기를 원본 상태로 되돌린다.
        onCurveEditingEnded?(self)
    }

    func apply(to image: NSImage, brightness: CGFloat = 0) -> NSImage? {
        guard let cgImage = image.cgImageForPixelEditing() else { return nil }

        if isDefaultCurve && brightness == 0 {
            return image
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bitsPerComponent = 8
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard didDraw else { return nil }

        let brightnessOffset = Int((brightness * 255).rounded())
        var index = 0
        while index < pixels.count {
            pixels[index] = clampedByte(Int(lut[Int(pixels[index])]) + brightnessOffset)
            pixels[index + 1] = clampedByte(Int(lut[Int(pixels[index + 1])]) + brightnessOffset)
            pixels[index + 2] = clampedByte(Int(lut[Int(pixels[index + 2])]) + brightnessOffset)
            index += bytesPerPixel
        }

        let outputCGImage = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: bitsPerComponent,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                return nil
            }

            return context.makeImage()
        }

        guard let outputCGImage = outputCGImage else { return nil }
        return NSImage(cgImage: outputCGImage, size: image.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0, bounds.height > 0 else {
            return
        }

        drawBorder(in: context)
        drawGrid(in: context)
        drawCurve(in: context)
        drawControlPoints(in: context)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        isEditing = true
        virtualPoint = curvePoint(fromViewPoint: location)
        selectedPointIndex = nearestPointIndex(to: virtualPoint!)

        if let selectedPointIndex = selectedPointIndex {
            points[selectedPointIndex] = virtualPoint!.clampedToCurveRange
        } else {
            rebuildLUT(using: workingPoints())
            needsDisplay = true
        }

        onCurveChanged?(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing else { return }

        let location = convert(event.locationInWindow, from: nil)
        virtualPoint = curvePoint(fromViewPoint: location)

        if let selectedPointIndex = selectedPointIndex {
            points[selectedPointIndex] = virtualPoint!.clampedToCurveRange
        } else {
            rebuildLUT(using: workingPoints())
            needsDisplay = true
        }

        onCurveChanged?(self)
    }

    override func mouseUp(with event: NSEvent) {
        finishEditing(with: convert(event.locationInWindow, from: nil))
    }

    private func finishEditing(with location: CGPoint?) {
        guard isEditing else { return }

        let curvePoint = location.map { self.curvePoint(fromViewPoint: $0) } ?? virtualPoint

        if let curvePoint = curvePoint, curvePoint.isInsideCurveRange {
            let clampedPoint = curvePoint.clampedToCurveRange

            if let selectedPointIndex = selectedPointIndex {
                points[selectedPointIndex] = clampedPoint
            } else {
                upsertPoint(clampedPoint)
            }
        } else if let selectedPointIndex = selectedPointIndex, points.count > 2 {
            points.remove(at: selectedPointIndex)
        }

        points.sort { $0.x < $1.x }
        isEditing = false
        selectedPointIndex = nil
        virtualPoint = nil
        rebuildLUT()
        needsDisplay = true

        onCurveChanged?(self)
        onCurveEditingEnded?(self)
    }

    private func drawBorder(in context: CGContext) {
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 1, dy: 1))
    }

    private func drawGrid(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(gridColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 3])

        for index in 1..<4 {
            let x = bounds.width * CGFloat(index) / 4
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))

            let y = bounds.height * CGFloat(index) / 4
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: bounds.width, y: y))
        }

        context.strokePath()
        context.restoreGState()
    }

    private func drawCurve(in context: CGContext) {
        context.setStrokeColor(curveColor.cgColor)
        context.setLineWidth(2)

        for x in 0..<lut.count {
            let point = viewPoint(fromCurvePoint: CGPoint(x: CGFloat(x), y: CGFloat(lut[x])))
            if x == 0 {
                context.move(to: point)
            } else {
                context.addLine(to: point)
            }
        }

        context.strokePath()
    }

    private func drawControlPoints(in context: CGContext) {
        context.setStrokeColor(pointColor.cgColor)
        context.setFillColor(pointColor.cgColor)
        context.setLineWidth(2)

        for point in workingPoints() where point.isInsideCurveRange {
            let viewPoint = viewPoint(fromCurvePoint: point.clampedToCurveRange)
            let rect = CGRect(
                x: viewPoint.x - controlPointRadius,
                y: viewPoint.y - controlPointRadius,
                width: controlPointRadius * 2,
                height: controlPointRadius * 2
            )
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    private func rebuildLUT() {
        rebuildLUT(using: points)
    }

    private func rebuildLUT(using sourcePoints: [CGPoint]) {
        lut = Self.makeLUT(from: sourcePoints)
    }

    private func workingPoints() -> [CGPoint] {
        guard isEditing, selectedPointIndex == nil, let virtualPoint = virtualPoint else {
            return points
        }

        return (points + [virtualPoint.clampedToCurveRange]).sorted { $0.x < $1.x }
    }

    private func nearestPointIndex(to point: CGPoint) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (index, currentPoint) in points.enumerated() {
            let distance = hypot(currentPoint.x - point.x, currentPoint.y - point.y)
            if distance <= selectionRadius, distance < bestDistance {
                bestIndex = index
                bestDistance = distance
            }
        }

        return bestIndex
    }

    private func upsertPoint(_ point: CGPoint) {
        let roundedX = point.x.rounded()

        if let index = points.firstIndex(where: { $0.x.rounded() == roundedX }) {
            points[index] = CGPoint(x: roundedX, y: point.y)
        } else {
            points.append(CGPoint(x: roundedX, y: point.y))
        }
    }

    private func curvePoint(fromViewPoint point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let x = point.x / bounds.width * 255
        let y = (1 - point.y / bounds.height) * 255
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func viewPoint(fromCurvePoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x / 255 * bounds.width,
            y: bounds.height - point.y / 255 * bounds.height
        )
    }

    private var isDefaultCurve: Bool {
        points.count == 2 &&
            points[0] == CGPoint(x: 0, y: 0) &&
            points[1] == CGPoint(x: 255, y: 255) &&
            virtualPoint == nil
    }

    private static func makeLUT(from sourcePoints: [CGPoint]) -> [UInt8] {
        let sortedPoints = normalizedPoints(from: sourcePoints)

        guard sortedPoints.count >= 2 else {
            return (0...255).map { UInt8($0) }
        }

        let xs = sortedPoints.map { Double($0.x) }
        let ys = sortedPoints.map { Double($0.y) }
        let secondDerivatives = secondDerivativesForNaturalSpline(xs: xs, ys: ys)

        return (0...255).map { x in
            let value = splineValue(
                at: Double(x),
                xs: xs,
                ys: ys,
                secondDerivatives: secondDerivatives
            )
            return clampedByte(Int(value.rounded()))
        }
    }

    private static func normalizedPoints(from sourcePoints: [CGPoint]) -> [CGPoint] {
        let sortedPoints = sourcePoints
            .map { $0.clampedToCurveRange }
            .sorted { $0.x < $1.x }

        var uniquePoints: [CGPoint] = []
        for point in sortedPoints {
            let roundedPoint = CGPoint(x: point.x.rounded(), y: point.y.rounded())
            if let last = uniquePoints.last, last.x == roundedPoint.x {
                uniquePoints[uniquePoints.count - 1] = roundedPoint
            } else {
                uniquePoints.append(roundedPoint)
            }
        }

        return uniquePoints
    }

    private static func secondDerivativesForNaturalSpline(xs: [Double], ys: [Double]) -> [Double] {
        let count = xs.count
        guard count > 2 else {
            return Array(repeating: 0, count: count)
        }

        var second = Array(repeating: 0.0, count: count)
        var scratch = Array(repeating: 0.0, count: count)

        for index in 1..<(count - 1) {
            let sig = (xs[index] - xs[index - 1]) / (xs[index + 1] - xs[index - 1])
            let p = sig * second[index - 1] + 2
            second[index] = (sig - 1) / p

            let leftSlope = (ys[index] - ys[index - 1]) / (xs[index] - xs[index - 1])
            let rightSlope = (ys[index + 1] - ys[index]) / (xs[index + 1] - xs[index])
            scratch[index] = (6 * (rightSlope - leftSlope) / (xs[index + 1] - xs[index - 1]) -
                sig * scratch[index - 1]) / p
        }

        for index in stride(from: count - 2, through: 0, by: -1) {
            second[index] = second[index] * second[index + 1] + scratch[index]
        }

        return second
    }

    private static func splineValue(
        at x: Double,
        xs: [Double],
        ys: [Double],
        secondDerivatives: [Double]
    ) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }

        var low = 0
        var high = xs.count - 1

        while high - low > 1 {
            let middle = (high + low) / 2
            if xs[middle] > x {
                high = middle
            } else {
                low = middle
            }
        }

        let distance = xs[high] - xs[low]
        guard distance > 0 else {
            return ys[low]
        }

        let a = (xs[high] - x) / distance
        let b = (x - xs[low]) / distance

        return a * ys[low] + b * ys[high] +
            ((a * a * a - a) * secondDerivatives[low] +
             (b * b * b - b) * secondDerivatives[high]) * distance * distance / 6
    }
}

private extension NSImage {
    func cgImageForPixelEditing() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

private extension CGPoint {
    var isInsideCurveRange: Bool {
        x >= 0 && x <= 255 && y >= 0 && y <= 255
    }

    var clampedToCurveRange: CGPoint {
        CGPoint(
            x: min(255, max(0, x)),
            y: min(255, max(0, y))
        )
    }
}

private func clampedByte(_ value: Int) -> UInt8 {
    UInt8(min(255, max(0, value)))
}
