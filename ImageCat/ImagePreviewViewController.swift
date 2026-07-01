//
//  ImagePreviewViewController.swift
//  ImageCat
//

import Cocoa
import CoreImage

class ImagePreviewViewController: NSViewController {
    // 백그라운드 렌더링 큐로 넘길 커브 미리보기 요청 정보를 한데 묶는다.
    private struct RenderRequest {
        // 오래된 렌더링 결과가 최신 화면을 덮어쓰지 않도록 요청 시점의 세대값을 저장한다.
        let generation: Int
        // NSImage를 백그라운드에서 직접 만지지 않도록 미리 CGImage로 변환해 전달한다.
        let sourceCGImage: CGImage
        // 다운샘플된 CGImage를 원래 표시 크기로 보여주기 위한 이미지 크기다.
        let imageSize: NSSize
        // 커브 컨트롤에서 계산한 0...255 색상 변환 테이블이다.
        let lut: [UInt8]
        // 드래그 중에는 낮은 해상도, 편집 종료 후에는 높은 해상도로 렌더링한다.
        let maxPreviewDimension: Int
    }

    var imageURL: URL? {
        didSet {
            updateImage()
        }
    }

    private let imageView = NSImageView()
    private let annotationOverlayView = AnnotationOverlayView()
    private let emptyLabel = NSTextField(labelWithString: "이미지를 선택하세요.")
    // Core Image 렌더러를 재사용해서 GPU 렌더링 컨텍스트 생성 비용을 줄인다.
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    // Core Image 렌더링 준비와 결과 생성을 메인 스레드 밖에서 처리한다.
    private let renderQueue = DispatchQueue(label: "ImageCat.curveRenderQueue", qos: .userInitiated)
    // 선택된 이미지를 캐시해서 커브 변경 때마다 디스크에서 다시 읽지 않는다.
    private var originalImage: NSImage?
    // 이미지 선택/커브 변경마다 증가시켜 늦게 끝난 렌더링 결과를 버린다.
    private var renderGeneration = 0
    // 렌더링이 이미 진행 중일 때 들어온 가장 최신 요청만 보관한다.
    private var pendingRenderRequest: RenderRequest?
    // 동시에 여러 렌더 작업이 큐에 쌓이지 않도록 실행 상태를 추적한다.
    private var isRenderScheduled = false
    
    private var imageControlViewController: ImageControlViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImageControlViewController }
            .first
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        updateImage()
    }

    private func configureView() {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        annotationOverlayView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(annotationOverlayView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            annotationOverlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            annotationOverlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            annotationOverlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
            annotationOverlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateImage() {
        guard isViewLoaded else { return }

        guard let imageURL = imageURL, let image = NSImage(contentsOf: imageURL) else {
            renderGeneration += 1
            originalImage = nil
            pendingRenderRequest = nil
            imageView.image = nil
            annotationOverlayView.annotation = nil
            annotationOverlayView.visibleShapeIndexes = []
            imageControlViewController?.updatePolygonLabels(from: nil)
            emptyLabel.isHidden = false
            return
        }

        renderGeneration += 1
        originalImage = image
        pendingRenderRequest = nil
        imageView.image = image

        let annotation = Self.loadAnnotation(
            for: imageURL,
            fallbackImageSize: image.pixelSizeForPreviewRendering()
        )

        annotationOverlayView.annotation = annotation
        imageControlViewController?.updatePolygonLabels(from: annotation)

        emptyLabel.isHidden = true
    }

    func setVisibleAnnotationShapeIndexes(_ indexes: Set<Int>) {
        annotationOverlayView.visibleShapeIndexes = indexes
    }

    var isPolygonEditingEnabled: Bool {
        return annotationOverlayView.isEditingEnabled
    }

    func setPolygonEditingEnabled(_ isEnabled: Bool) {
        annotationOverlayView.isEditingEnabled = isEnabled
    }

    // 커브를 이미지 미리보기에 적용한다. 드래그 중에는 빠른 저해상도 렌더링을 사용한다.
    func applyCurve(using curveControl: ImageCurveControl, isInteractive: Bool = false) {
        guard let originalImage = originalImage,
              let sourceCGImage = originalImage.cgImageForPreviewRendering() else { return }

        // 이 호출 이후 완료되는 이전 렌더링 작업은 오래된 결과로 취급한다.
        renderGeneration += 1
        let generation = renderGeneration
        let lut = curveControl.lut

        if Self.isIdentityLUT(lut) {
            // 기본 커브라면 렌더링하지 않고 캐시된 원본 이미지를 즉시 보여준다.
            pendingRenderRequest = nil
            imageView.image = originalImage
            return
        }

        // 렌더 작업이 이미 실행 중이면 이 요청이 최신 대기 요청으로 교체된다.
        pendingRenderRequest = RenderRequest(
            generation: generation,
            sourceCGImage: sourceCGImage,
            imageSize: originalImage.size,
            lut: lut,
            maxPreviewDimension: isInteractive ? 1600 : 3200
        )
        scheduleNextRenderIfNeeded()
    }

    // 실행 중인 렌더가 없을 때만 최신 요청 하나를 백그라운드 큐에 올린다.
    private func scheduleNextRenderIfNeeded() {
        guard !isRenderScheduled, let request = pendingRenderRequest else { return }

        pendingRenderRequest = nil
        isRenderScheduled = true

        renderQueue.async { [weak self] in
            let renderedImage = Self.renderPreviewImage(
                from: request.sourceCGImage,
                imageSize: request.imageSize,
                lut: request.lut,
                maxPreviewDimension: request.maxPreviewDimension
            )

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRenderScheduled = false

                // 현재 세대와 일치하는 결과만 화면에 반영해서 오래된 프리뷰 깜빡임을 막는다.
                if request.generation == self.renderGeneration, let renderedImage = renderedImage {
                    self.imageView.image = renderedImage
                    self.emptyLabel.isHidden = true
                }

                // 렌더링 중 새 요청이 들어왔으면 이어서 최신 요청만 처리한다.
                self.scheduleNextRenderIfNeeded()
            }
        }
    }

    // 원본 이미지를 필요 크기로 줄인 뒤 Core Image 컬러 큐브로 LUT를 적용한다.
    private static func renderPreviewImage(
        from sourceCGImage: CGImage,
        imageSize: NSSize,
        lut: [UInt8],
        maxPreviewDimension: Int
    ) -> NSImage? {
        let sourceWidth = sourceCGImage.width
        let sourceHeight = sourceCGImage.height
        let largestSourceDimension = max(sourceWidth, sourceHeight)
        let scale = largestSourceDimension > maxPreviewDimension
            ? CGFloat(maxPreviewDimension) / CGFloat(largestSourceDimension)
            : 1
        let width = max(1, Int((CGFloat(sourceWidth) * scale).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * scale).rounded()))

        let inputImage = CIImage(cgImage: sourceCGImage)
        let scaledImage = inputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)

        guard let colorCubeFilter = CIFilter(name: "CIColorCube") else { return nil }
        let cubeDimension = maxPreviewDimension <= 1600 ? 32 : 64
        colorCubeFilter.setValue(scaledImage, forKey: kCIInputImageKey)
        colorCubeFilter.setValue(cubeDimension, forKey: "inputCubeDimension")
        colorCubeFilter.setValue(makeColorCubeData(from: lut, dimension: cubeDimension), forKey: "inputCubeData")

        guard let outputImage = colorCubeFilter.outputImage,
              let outputCGImage = ciContext.createCGImage(outputImage, from: outputExtent) else {
            return nil
        }

        return NSImage(cgImage: outputCGImage, size: imageSize)
    }

    // 1D 커브 LUT를 Core Image가 GPU에서 사용할 수 있는 3D 컬러 큐브 데이터로 변환한다.
    private static func makeColorCubeData(from lut: [UInt8], dimension: Int) -> Data {
        var cube = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        var offset = 0

        for blueIndex in 0..<dimension {
            let blue = colorCubeValue(for: blueIndex, dimension: dimension, lut: lut)
            for greenIndex in 0..<dimension {
                let green = colorCubeValue(for: greenIndex, dimension: dimension, lut: lut)
                for redIndex in 0..<dimension {
                    let red = colorCubeValue(for: redIndex, dimension: dimension, lut: lut)

                    cube[offset] = red
                    cube[offset + 1] = green
                    cube[offset + 2] = blue
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return cube.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    // 컬러 큐브 인덱스를 LUT 인덱스로 환산해 0...1 범위의 Core Image 색상값으로 바꾼다.
    private static func colorCubeValue(for cubeIndex: Int, dimension: Int, lut: [UInt8]) -> Float {
        let lutIndex = Int((CGFloat(cubeIndex) / CGFloat(dimension - 1) * 255).rounded())
        return Float(lut[lutIndex]) / 255
    }

    // LUT가 기본 직선 커브인지 확인해 불필요한 픽셀 처리를 건너뛴다.
    private static func isIdentityLUT(_ lut: [UInt8]) -> Bool {
        guard lut.count == 256 else { return false }
        for index in 0..<256 where lut[index] != UInt8(index) {
            return false
        }
        return true
    }

    private static func loadAnnotation(for imageURL: URL, fallbackImageSize: NSSize?) -> LabelMeAnnotation? {
        let jsonURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: jsonURL)
            var annotation = try JSONDecoder().decode(LabelMeAnnotation.self, from: data)
            if annotation.imageSize == .zero, let fallbackImageSize = fallbackImageSize {
                annotation.imageWidth = fallbackImageSize.width
                annotation.imageHeight = fallbackImageSize.height
            }
            return annotation
        } catch {
            print("Annotation JSON 읽기 실패: \(jsonURL.path) - \(error.localizedDescription)")
            return nil
        }
    }
}

private extension NSImage {
    // 커브 렌더링에 사용할 CGImage를 안정적으로 꺼내기 위한 헬퍼다.
    func cgImageForPreviewRendering() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    func pixelSizeForPreviewRendering() -> NSSize? {
        guard let cgImage = cgImageForPreviewRendering() else { return nil }
        return NSSize(width: cgImage.width, height: cgImage.height)
    }
}

private final class AnnotationOverlayView: NSView {
    var annotation: LabelMeAnnotation? = nil {
        didSet {
            labelColors = LabelColorProvider.colors(for: annotation?.shapes.map { $0.label } ?? [])
            if oldValue?.shapes.count != annotation?.shapes.count {
                visibleShapeIndexes = Set(annotation?.shapes.indices ?? 0..<0)
            }
            needsDisplay = true
        }
    }

    var visibleShapeIndexes: Set<Int> = [] {
        didSet {
            needsDisplay = true
        }
    }

    private var labelColors: [String: NSColor] = [:]
    private var trackingArea: NSTrackingArea?
    private var hoveredShapeIndex: Int?
    private var draggingShapeIndex: Int?
    private var lastDragImagePoint: CGPoint?

    var isEditingEnabled = false {
        didSet {
            hoveredShapeIndex = nil
            draggingShapeIndex = nil
            lastDragImagePoint = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            if !isEditingEnabled {
                NSCursor.arrow.set()
            }
        }
    }

    override var isFlipped: Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return isEditingEnabled ? self : nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEditingEnabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        updateHoveredShape(at: location)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredShapeIndex = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditingEnabled else { return }

        let location = convert(event.locationInWindow, from: nil)
        draggingShapeIndex = shapeIndex(at: location)
        hoveredShapeIndex = draggingShapeIndex
        lastDragImagePoint = imagePoint(for: location)

        if draggingShapeIndex != nil {
            NSCursor.closedHand.set()
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditingEnabled,
              let draggingShapeIndex = draggingShapeIndex,
              var annotation = annotation,
              annotation.shapes.indices.contains(draggingShapeIndex),
              let previousImagePoint = lastDragImagePoint else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard let currentImagePoint = imagePoint(for: location) else { return }

        let delta = CGPoint(
            x: currentImagePoint.x - previousImagePoint.x,
            y: currentImagePoint.y - previousImagePoint.y
        )

        for pointIndex in annotation.shapes[draggingShapeIndex].points.indices {
            annotation.shapes[draggingShapeIndex].points[pointIndex].x += delta.x
            annotation.shapes[draggingShapeIndex].points[pointIndex].y += delta.y
        }

        self.annotation = annotation
        lastDragImagePoint = currentImagePoint
        hoveredShapeIndex = draggingShapeIndex
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        draggingShapeIndex = nil
        lastDragImagePoint = nil

        let location = convert(event.locationInWindow, from: nil)
        updateHoveredShape(at: location)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        guard imageRect.width > 0, imageRect.height > 0 else { return }

        NSGraphicsContext.current?.cgContext.setLineJoin(.round)
        NSGraphicsContext.current?.cgContext.setLineCap(.round)

        for (shapeIndex, shape) in annotation.shapes.enumerated() {
            guard visibleShapeIndexes.contains(shapeIndex) else { continue }

            let viewPoints = shape.points.map { point in
                CGPoint(
                    x: imageRect.minX + point.x * imageRect.width / annotation.imageSize.width,
                    y: imageRect.minY + point.y * imageRect.height / annotation.imageSize.height
                )
            }
            guard viewPoints.count >= 2 else { continue }

            let color = labelColors[shape.label] ?? .systemBlue
            let path = makePath(for: shape, points: viewPoints)

            if isEditingEnabled && (shapeIndex == hoveredShapeIndex || shapeIndex == draggingShapeIndex) {
                color.withAlphaComponent(0.28).setFill()
                path.fill()
            }

            color.setStroke()
            path.lineWidth = 2
            path.stroke()
            drawVertexHandles(at: viewPoints, color: color)
        }
    }

    private func fittedImageRect(for imageSize: NSSize) -> CGRect {
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func makePath(for shape: LabelMeAnnotation.Shape, points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 2

        if shape.shapeType == "rectangle", points.count >= 2 {
            let firstPoint = points[0]
            let secondPoint = points[1]
            let rect = CGRect(
                x: min(firstPoint.x, secondPoint.x),
                y: min(firstPoint.y, secondPoint.y),
                width: abs(secondPoint.x - firstPoint.x),
                height: abs(secondPoint.y - firstPoint.y)
            )
            path.appendRect(rect)
        } else {
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.close()
        }

        return path
    }

    private func drawVertexHandles(at points: [CGPoint], color: NSColor) {
        color.setFill()

        for point in points {
            let handleRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSBezierPath(ovalIn: handleRect).fill()
        }
    }

    private func updateHoveredShape(at location: CGPoint) {
        let newHoveredShapeIndex = shapeIndex(at: location)
        if newHoveredShapeIndex != hoveredShapeIndex {
            hoveredShapeIndex = newHoveredShapeIndex
            needsDisplay = true
        }

        if newHoveredShapeIndex == nil {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    private func shapeIndex(at location: CGPoint) -> Int? {
        guard isEditingEnabled,
              let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0,
              let imagePoint = imagePoint(for: location) else {
            return nil
        }

        for shapeIndex in annotation.shapes.indices.reversed() {
            guard visibleShapeIndexes.contains(shapeIndex) else { continue }

            if contains(imagePoint, in: annotation.shapes[shapeIndex]) {
                return shapeIndex
            }
        }

        return nil
    }

    private func imagePoint(for viewPoint: CGPoint) -> CGPoint? {
        guard let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return nil
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        guard imageRect.contains(viewPoint), imageRect.width > 0, imageRect.height > 0 else {
            return nil
        }

        return CGPoint(
            x: (viewPoint.x - imageRect.minX) * annotation.imageSize.width / imageRect.width,
            y: (viewPoint.y - imageRect.minY) * annotation.imageSize.height / imageRect.height
        )
    }

    private func contains(_ point: CGPoint, in shape: LabelMeAnnotation.Shape) -> Bool {
        if shape.shapeType == "rectangle", shape.points.count >= 2 {
            let firstPoint = shape.points[0]
            let secondPoint = shape.points[1]
            let rect = CGRect(
                x: min(firstPoint.x, secondPoint.x),
                y: min(firstPoint.y, secondPoint.y),
                width: abs(secondPoint.x - firstPoint.x),
                height: abs(secondPoint.y - firstPoint.y)
            )
            return rect.contains(point)
        }

        return polygonContains(point, points: shape.points.map { CGPoint(x: $0.x, y: $0.y) })
    }

    private func polygonContains(_ point: CGPoint, points: [CGPoint]) -> Bool {
        guard points.count >= 3 else { return false }

        var isInside = false
        var previousIndex = points.count - 1

        for index in points.indices {
            let currentPoint = points[index]
            let previousPoint = points[previousIndex]

            let crossesY = (currentPoint.y > point.y) != (previousPoint.y > point.y)
            if crossesY {
                let xIntersection = (previousPoint.x - currentPoint.x) *
                    (point.y - currentPoint.y) /
                    (previousPoint.y - currentPoint.y) +
                    currentPoint.x
                if point.x < xIntersection {
                    isInside.toggle()
                }
            }

            previousIndex = index
        }

        return isInside
    }
}
