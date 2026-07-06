//
//  ImagePreviewViewController.swift
//  ImageCat
//

import Cocoa
import CoreImage

enum PolygonInteractionMode {
    case inactive
    case create
    case edit
}

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
        // 새 도형이 추가되면 오른쪽 라벨 목록도 즉시 최신 annotation 기준으로 갱신한다.
        annotationOverlayView.onAnnotationChanged = { [weak self] annotation in
            self?.imageControlViewController?.updatePolygonLabels(from: annotation)
        }
        // 오버레이는 화면 입력만 담당하고, label 입력 창은 뷰 컨트롤러가 띄운다.
        annotationOverlayView.onLabelRequested = { [weak self] labels in
            self?.requestAnnotationLabel(existingLabels: labels)
        }

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

    // 파일 리스트가 폴더 전체 JSON scan으로 만든 label-color set을 overlay에 전달한다.
    func setFolderLabelColorPairs(_ pairs: Set<LabelColorPair>) {
        annotationOverlayView.folderLabelColorPairs = pairs
    }

    var isPolygonEditingEnabled: Bool {
        return annotationOverlayView.isEditingEnabled
    }

    var polygonInteractionMode: PolygonInteractionMode {
        return annotationOverlayView.interactionMode
    }

    func setPolygonEditingEnabled(_ isEnabled: Bool) {
        annotationOverlayView.isEditingEnabled = isEnabled
    }

    func setPolygonInteractionMode(_ mode: PolygonInteractionMode) {
        annotationOverlayView.interactionMode = mode
    }

    func saveCurrentAnnotation() throws {
        guard let imageURL else {
            throw AnnotationSaveError.missingImage
        }

        guard let annotation = annotationOverlayView.annotation else {
            throw AnnotationSaveError.missingAnnotation
        }

        try Self.saveAnnotation(annotation, for: imageURL)
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
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            guard let fallbackImageSize = fallbackImageSize else { return nil }
            // JSON 파일이 아직 없어도 create 모드에서 새 라벨을 만들 수 있게 빈 annotation을 준비한다.
            return LabelMeAnnotation(
                shapes: [],
                imageHeight: fallbackImageSize.height,
                imageWidth: fallbackImageSize.width
            )
        }

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

    private func requestAnnotationLabel(existingLabels: [String]) -> String? {
        // 도형이 닫히거나 rectangle 드래그가 끝난 뒤 label을 확정받는다.
        let prompt = AnnotationLabelPrompt(existingLabels: existingLabels)
        return prompt.runModal(attachedTo: view.window)
    }

    private static func saveAnnotation(_ annotation: LabelMeAnnotation, for imageURL: URL) throws {
        let jsonURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        var root: [String: Any] = [:]

        // LabelMe JSON의 부가 필드는 보존하고 shapes/이미지 크기만 최신 상태로 갱신한다.
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            let data = try Data(contentsOf: jsonURL)
            root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        let existingShapes = root["shapes"] as? [[String: Any]] ?? []
        root["imageWidth"] = jsonNumber(from: annotation.imageWidth)
        root["imageHeight"] = jsonNumber(from: annotation.imageHeight)
        root["shapes"] = annotation.shapes.enumerated().map { index, shape in
            var shapeJSON = index < existingShapes.count ? existingShapes[index] : [:]
            shapeJSON["label"] = shape.label
            shapeJSON["points"] = shape.points.map { point in
                [jsonNumber(from: point.x), jsonNumber(from: point.y)]
            }

            if let shapeType = shape.shapeType {
                shapeJSON["shape_type"] = shapeType
            } else {
                shapeJSON.removeValue(forKey: "shape_type")
            }

            return shapeJSON
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: jsonURL, options: .atomic)
    }

    private static func jsonNumber(from value: CGFloat) -> Any {
        let roundedValue = value.rounded()
        if abs(value - roundedValue) < 0.0001 {
            return Int(roundedValue)
        }

        return Double(value)
    }
}

private enum AnnotationSaveError: LocalizedError {
    case missingImage
    case missingAnnotation

    var errorDescription: String? {
        switch self {
        case .missingImage:
            return "저장할 이미지가 선택되어 있지 않습니다."
        case .missingAnnotation:
            return "저장할 라벨링 JSON이 없습니다."
        }
    }
}

// create 모드에서 새 도형을 확정할 때 label을 입력하거나 기존 label을 고르게 하는 창이다.
private final class AnnotationLabelPrompt: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Layout {
        static let width: CGFloat = 520
        static let height: CGFloat = 300
        static let fieldHeight: CGFloat = 32
        static let spacing: CGFloat = 12
        static let groupFieldWidth: CGFloat = 110
    }

    private let labels: [String]
    private let defaultLabel: String?
    private let labelField = NSTextField()
    private let groupField = NSTextField()
    private let tableView = NSTableView()

    init(existingLabels: [String]) {
        defaultLabel = existingLabels.last
        // 같은 label이 여러 shape에 쓰여도 목록에는 한 번만 보여준다.
        var seenLabels = Set<String>()
        labels = existingLabels.filter { label in
            seenLabels.insert(label).inserted
        }
        super.init()
    }

    func runModal(attachedTo window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Label"
        alert.informativeText = ""
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeAccessoryView()
        alert.window.initialFirstResponder = labelField

        // 새 라벨을 빠르게 추가할 수 있도록 가장 최근에 사용된 label을 기본값으로 둔다.
        if let defaultLabel = defaultLabel,
           let defaultRow = labels.firstIndex(of: defaultLabel) {
            labelField.stringValue = defaultLabel
            tableView.selectRowIndexes(IndexSet(integer: defaultRow), byExtendingSelection: false)
        } else if let lastLabel = labels.last {
            labelField.stringValue = lastLabel
            tableView.selectRowIndexes(IndexSet(integer: labels.count - 1), byExtendingSelection: false)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return labels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < labels.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("AnnotationLabelPromptCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.font = .systemFont(ofSize: 18)
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = labels[row]
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < labels.count else { return }
        // 목록의 label을 선택하면 입력칸에 복사해서 바로 OK할 수 있게 한다.
        labelField.stringValue = labels[row]
        labelField.selectText(nil)
    }

    private func makeAccessoryView() -> NSView {
        let accessoryView = NSView(
            frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        )

        labelField.font = .systemFont(ofSize: 22)
        labelField.placeholderString = "Label"
        labelField.frame = NSRect(
            x: 0,
            y: Layout.height - Layout.fieldHeight,
            width: Layout.width - Layout.groupFieldWidth - Layout.spacing,
            height: Layout.fieldHeight
        )

        groupField.font = .systemFont(ofSize: 22)
        groupField.placeholderString = "Group ID"
        groupField.isEnabled = false
        groupField.frame = NSRect(
            x: labelField.frame.maxX + Layout.spacing,
            y: labelField.frame.minY,
            width: Layout.groupFieldWidth,
            height: Layout.fieldHeight
        )

        let scrollView = NSScrollView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Layout.width,
                height: labelField.frame.minY - Layout.spacing
            )
        )
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AnnotationLabelPromptColumn"))
        column.width = Layout.width
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = scrollView.bounds

        scrollView.documentView = tableView

        accessoryView.addSubview(labelField)
        accessoryView.addSubview(groupField)
        accessoryView.addSubview(scrollView)
        return accessoryView
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
    private enum HandleStyle {
        static let normalDiameter: CGFloat = 10
        static let selectedSide: CGFloat = 12
        static let hitDiameter: CGFloat = 18
        static let strokeWidth: CGFloat = 2
    }

    // create 모드에서 임시로 그리는 선, 점, 닫힘 표시의 화면 스타일이다.
    private enum CreationStyle {
        static let handleDiameter: CGFloat = HandleStyle.normalDiameter
        static let activeHandleDiameter: CGFloat = HandleStyle.normalDiameter * 2
        static let closeHitDiameter: CGFloat = 34
        static let lineWidth: CGFloat = 3
        static let minimumSegmentLength: CGFloat = 3
        static let minimumRectangleSide: CGFloat = 3
        static let fallbackColor = NSColor.systemGreen
    }

    // Create Polygons 버튼은 polygon이 기본이고, Cmd+R/Cmd+J로 생성 타입만 바꾼다.
    private enum CreationShapeKind {
        case polygon
        case rectangle
    }

    private struct VertexSelection: Equatable {
        let shapeIndex: Int
        let vertexIndex: Int
    }

    var annotation: LabelMeAnnotation? = nil {
        didSet {
            let labels = annotation?.shapes.map { $0.label } ?? []
            updateLabelColors()
            if let lastCreatedLabel = lastCreatedLabel, !labels.contains(lastCreatedLabel) {
                self.lastCreatedLabel = nil
            }
            if oldValue?.shapes.count != annotation?.shapes.count {
                let newIndexes = Set(annotation?.shapes.indices ?? 0..<0)
                if oldValue == nil || visibleShapeIndexes.isEmpty {
                    visibleShapeIndexes = newIndexes
                } else {
                    // 새 shape를 추가해도 사용자가 꺼 둔 기존 label 표시 상태는 유지한다.
                    let oldIndexes = Set(oldValue?.shapes.indices ?? 0..<0)
                    let addedIndexes = newIndexes.subtracting(oldIndexes)
                    visibleShapeIndexes = visibleShapeIndexes
                        .intersection(newIndexes)
                        .union(addedIndexes)
                }
            }
            needsDisplay = true
        }
    }

    var visibleShapeIndexes: Set<Int> = [] {
        didSet {
            needsDisplay = true
        }
    }

    // 폴더 전체 기준 색상 set이다. annotation이 바뀌거나 set이 갱신되면 labelColors를 다시 만든다.
    var folderLabelColorPairs: Set<LabelColorPair> = [] {
        didSet {
            updateLabelColors()
            needsDisplay = true
        }
    }

    private var labelColors: [String: NSColor] = [:]
    private var trackingArea: NSTrackingArea?
    private var hoveredShapeIndex: Int?
    private var hoveredVertex: VertexSelection?
    private var draggingVertex: VertexSelection?
    // 꼭지점이 아닌 도형 내부를 잡았을 때 전체 shape를 이동하기 위한 drag 상태다.
    private var draggingShapeIndex: Int?
    private var shapeDragLastImagePoint: CGPoint?
    private var creationShapeKind: CreationShapeKind = .polygon
    private var polygonCreationPoints: [CGPoint] = []
    private var creationDragStartPoint: CGPoint?
    private var creationDragCurrentPoint: CGPoint?
    private var isCloseToFirstCreationPoint = false
    private var lastCreatedLabel: String?
    // 생성 확정과 label 입력은 상위 컨트롤러와 협력해서 처리한다.
    var onAnnotationChanged: ((LabelMeAnnotation?) -> Void)?
    var onLabelRequested: (([String]) -> String?)?

    var interactionMode: PolygonInteractionMode = .inactive {
        didSet {
            guard oldValue != interactionMode else { return }
            // 모드가 바뀌면 선택 핸들과 작성 중인 임시 도형을 모두 정리한다.
            hoveredShapeIndex = nil
            hoveredVertex = nil
            draggingVertex = nil
            draggingShapeIndex = nil
            shapeDragLastImagePoint = nil
            cancelCreation()
            if interactionMode == .create {
                // create 모드는 항상 polygon 생성에서 시작하고 키보드 단축키를 받는다.
                creationShapeKind = .polygon
                window?.makeFirstResponder(self)
            }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            switch interactionMode {
            case .create:
                NSCursor.crosshair.set()
            case .inactive, .edit:
                NSCursor.arrow.set()
            }
        }
    }

    var isEditingEnabled: Bool {
        get {
            return interactionMode == .edit
        }
        set {
            interactionMode = newValue ? .edit : .inactive
        }
    }

    override var isFlipped: Bool {
        return true
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return interactionMode == .inactive ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        if interactionMode == .create {
            addCursorRect(bounds, cursor: .crosshair)
        }
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
            .cursorUpdate,
            .mouseMoved,
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if draggingVertex != nil || draggingShapeIndex != nil {
            return
        }

        hoveredShapeIndex = nil
        hoveredVertex = nil
        if interactionMode == .create {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if interactionMode == .create {
            // create 모드에서는 기존 shape hit-test를 하지 않고 새 도형 입력만 시작한다.
            beginCreationDrag(at: convert(event.locationInWindow, from: nil))
            return
        }

        guard interactionMode == .edit else { return }

        let location = convert(event.locationInWindow, from: nil)
        let selectedVertex = vertexSelection(at: location)
        let selectedShapeIndex = selectedVertex?.shapeIndex ?? shapeIndex(at: location)
        draggingVertex = selectedVertex
        // 꼭지점을 잡은 경우에는 vertex resize가 우선이고, 내부를 잡은 경우에만 shape 이동을 시작한다.
        draggingShapeIndex = selectedVertex == nil ? selectedShapeIndex : nil
        shapeDragLastImagePoint = draggingShapeIndex == nil ? nil : imagePoint(for: location)
        hoveredVertex = selectedVertex
        hoveredShapeIndex = selectedShapeIndex

        if selectedVertex != nil {
            NSCursor.pointingHand.set()
        } else if draggingShapeIndex != nil {
            NSCursor.closedHand.set()
        }

        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if interactionMode == .create {
            // polygon은 마지막 점에서 현재 위치까지, rectangle은 시작점에서 현재 위치까지 preview한다.
            updateCreationDrag(at: convert(event.locationInWindow, from: nil))
            return
        }

        guard interactionMode == .edit else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard let currentImagePoint = imagePoint(for: location) else { return }

        if let draggingVertex = draggingVertex {
            guard var annotation = annotation,
                  annotation.shapes.indices.contains(draggingVertex.shapeIndex) else {
                return
            }

            if isRectangle(annotation.shapes[draggingVertex.shapeIndex]) {
                updateRectangleCorner(
                    in: &annotation.shapes[draggingVertex.shapeIndex],
                    vertexIndex: draggingVertex.vertexIndex,
                    to: currentImagePoint
                )
            } else if annotation.shapes[draggingVertex.shapeIndex].points.indices.contains(draggingVertex.vertexIndex) {
                annotation.shapes[draggingVertex.shapeIndex].points[draggingVertex.vertexIndex].x = currentImagePoint.x
                annotation.shapes[draggingVertex.shapeIndex].points[draggingVertex.vertexIndex].y = currentImagePoint.y
            }

            self.annotation = annotation
            hoveredShapeIndex = draggingVertex.shapeIndex
            hoveredVertex = draggingVertex
            NSCursor.pointingHand.set()
            return
        }

        if let draggingShapeIndex = draggingShapeIndex,
           let previousImagePoint = shapeDragLastImagePoint {
            guard var annotation = annotation,
                  annotation.shapes.indices.contains(draggingShapeIndex) else {
                return
            }

            // 마지막 image 좌표와 현재 image 좌표의 차이를 모든 point에 더해 도형 전체를 이동한다.
            let deltaX = currentImagePoint.x - previousImagePoint.x
            let deltaY = currentImagePoint.y - previousImagePoint.y
            guard deltaX != 0 || deltaY != 0 else { return }

            for pointIndex in annotation.shapes[draggingShapeIndex].points.indices {
                annotation.shapes[draggingShapeIndex].points[pointIndex].x += deltaX
                annotation.shapes[draggingShapeIndex].points[pointIndex].y += deltaY
            }

            shapeDragLastImagePoint = currentImagePoint
            self.annotation = annotation
            hoveredShapeIndex = draggingShapeIndex
            hoveredVertex = nil
            NSCursor.closedHand.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if interactionMode == .create {
            // 드래그 종료 시 polygon은 점을 추가하거나 닫고, rectangle은 바로 확정을 시도한다.
            finishCreationDrag(at: convert(event.locationInWindow, from: nil))
            return
        }

        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil

        let location = convert(event.locationInWindow, from: nil)
        updateCursor(at: location)
    }

    override func keyDown(with event: NSEvent) {
        guard interactionMode == .create else {
            super.keyDown(with: event)
            return
        }

        // Esc는 현재 그리고 있던 임시 polygon/rectangle을 취소한다.
        if event.keyCode == 53 {
            cancelCreation()
            return
        }

        // create 모드 안에서 Cmd+R은 rectangle, Cmd+J는 polygon 생성으로 전환한다.
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "r":
                setCreationShapeKind(.rectangle)
                return
            case "j":
                setCreationShapeKind(.polygon)
                return
            default:
                break
            }
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard interactionMode == .create,
              event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        // 메뉴 단축키로 소비되기 전에 create 모드 전환 키를 오버레이에서 먼저 처리한다.
        switch key {
        case "r":
            setCreationShapeKind(.rectangle)
            return true
        case "j":
            setCreationShapeKind(.polygon)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
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

            let viewPoints = shape.points.map {
                viewPoint(for: CGPoint(x: $0.x, y: $0.y), imageRect: imageRect, imageSize: annotation.imageSize)
            }
            guard viewPoints.count >= 2 else { continue }

            let color = labelColors[shape.label] ?? .systemBlue
            let path = makePath(for: shape, points: viewPoints)
            let activeVertex = draggingVertex ?? hoveredVertex
            let isActiveShape = isEditingEnabled &&
                (
                    shapeIndex == hoveredShapeIndex ||
                    shapeIndex == draggingVertex?.shapeIndex ||
                    shapeIndex == draggingShapeIndex
                )

            if isActiveShape {
                color.withAlphaComponent(0.28).setFill()
                path.fill()
            }

            color.setStroke()
            path.lineWidth = 2
            path.stroke()
            drawVertexHandles(
                at: handleViewPoints(for: shape, imageRect: imageRect, imageSize: annotation.imageSize),
                color: color,
                activeVertexIndex: activeVertex?.shapeIndex == shapeIndex ? activeVertex?.vertexIndex : nil,
                usesEditingStyle: isActiveShape
            )
        }

        drawCreationPreview(imageRect: imageRect, imageSize: annotation.imageSize)
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

        if isRectangle(shape), let rect = rectangleBounds(for: points) {
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

    private func drawVertexHandles(
        at points: [CGPoint],
        color: NSColor,
        activeVertexIndex: Int?,
        usesEditingStyle: Bool
    ) {
        let handleStrokeColor = color
        let handleFillColor = usesEditingStyle ? NSColor.white : color

        for (index, point) in points.enumerated() {
            let isSelectedVertex = activeVertexIndex == index
            let side = isSelectedVertex ? HandleStyle.selectedSide : HandleStyle.normalDiameter
            let handleRect = CGRect(
                x: point.x - side / 2,
                y: point.y - side / 2,
                width: side,
                height: side
            )
            let handlePath = isSelectedVertex
                ? NSBezierPath(rect: handleRect)
                : NSBezierPath(ovalIn: handleRect)

            handleFillColor.setFill()
            handlePath.fill()
            handleStrokeColor.setStroke()
            handlePath.lineWidth = HandleStyle.strokeWidth
            handlePath.stroke()
        }
    }

    private func drawCreationPreview(imageRect: CGRect, imageSize: NSSize) {
        guard interactionMode == .create else { return }

        // 작성 중인 도형은 annotation에 넣기 전까지 preview로만 그린다.
        switch creationShapeKind {
        case .polygon:
            drawPolygonCreationPreview(imageRect: imageRect, imageSize: imageSize)
        case .rectangle:
            drawRectangleCreationPreview(imageRect: imageRect, imageSize: imageSize)
        }
    }

    private func drawPolygonCreationPreview(imageRect: CGRect, imageSize: NSSize) {
        guard !polygonCreationPoints.isEmpty else { return }

        let viewPoints = polygonCreationPoints.map {
            viewPoint(for: $0, imageRect: imageRect, imageSize: imageSize)
        }
        let currentViewPoint = creationDragCurrentPoint.map {
            viewPoint(for: $0, imageRect: imageRect, imageSize: imageSize)
        }
        // 첫 클릭 직후처럼 시작점과 현재점이 같을 때는 두 배 핸들이 겹쳐 보이지 않게 숨긴다.
        let shouldDrawCurrentHandle: Bool
        if let currentViewPoint = currentViewPoint,
           let startPoint = creationDragStartPoint {
            let startViewPoint = viewPoint(for: startPoint, imageRect: imageRect, imageSize: imageSize)
            shouldDrawCurrentHandle = distance(from: currentViewPoint, to: startViewPoint) > 0.5
        } else {
            shouldDrawCurrentHandle = currentViewPoint != nil
        }

        let path = NSBezierPath()
        path.lineWidth = CreationStyle.lineWidth
        path.move(to: viewPoints[0])
        for point in viewPoints.dropFirst() {
            path.line(to: point)
        }
        if let currentViewPoint = currentViewPoint {
            path.line(to: isCloseToFirstCreationPoint ? viewPoints[0] : currentViewPoint)
        }

        let color = creationColor()
        color.setStroke()
        path.stroke()

        // 확정된 꼭지점은 평소 class 색으로 채우고, 닫힘 직전에는 흰색으로 바꿔 닫힘 상태를 강조한다.
        let settledFillColor = isCloseToFirstCreationPoint ? NSColor.white : color
        for point in viewPoints {
            drawCreationHandle(
                at: point,
                diameter: CreationStyle.handleDiameter,
                fillColor: settledFillColor,
                strokeColor: color
            )
        }

        if let currentViewPoint = currentViewPoint, shouldDrawCurrentHandle, !isCloseToFirstCreationPoint {
            drawCreationHandle(
                at: currentViewPoint,
                diameter: CreationStyle.activeHandleDiameter,
                fillColor: color,
                strokeColor: color
            )
        }

        if isCloseToFirstCreationPoint {
            // 첫 점으로 돌아오면 닫을 수 있다는 신호로 이어질 꼭지점만 두 배 크기로 그린다.
            drawCreationHandle(
                at: viewPoints[0],
                diameter: CreationStyle.activeHandleDiameter,
                fillColor: .white,
                strokeColor: color
            )
        }
    }

    private func drawRectangleCreationPreview(imageRect: CGRect, imageSize: NSSize) {
        guard let startPoint = creationDragStartPoint,
              let currentPoint = creationDragCurrentPoint,
              let rect = rectangleBounds(for: [startPoint, currentPoint]) else {
            return
        }

        let viewRect = CGRect(
            x: imageRect.minX + rect.minX * imageRect.width / imageSize.width,
            y: imageRect.minY + rect.minY * imageRect.height / imageSize.height,
            width: rect.width * imageRect.width / imageSize.width,
            height: rect.height * imageRect.height / imageSize.height
        )
        let path = NSBezierPath(rect: viewRect)
        let color = creationColor()
        color.setStroke()
        path.lineWidth = CreationStyle.lineWidth
        path.stroke()

        let currentViewPoint = viewPoint(for: currentPoint, imageRect: imageRect, imageSize: imageSize)
        // rectangle은 저장/편집 모두 LabelMe rectangle 형식인 좌상단, 우하단 두 점만 보여준다.
        let topLeftPoint = CGPoint(x: viewRect.minX, y: viewRect.minY)
        let bottomRightPoint = CGPoint(x: viewRect.maxX, y: viewRect.maxY)
        let activePoint = distance(from: currentViewPoint, to: topLeftPoint) <
            distance(from: currentViewPoint, to: bottomRightPoint)
            ? topLeftPoint
            : bottomRightPoint

        for cornerPoint in [topLeftPoint, bottomRightPoint] where distance(from: cornerPoint, to: activePoint) > 0.5 {
            drawCreationHandle(
                at: cornerPoint,
                diameter: CreationStyle.handleDiameter,
                fillColor: color,
                strokeColor: color
            )
        }

        drawCreationHandle(
            at: activePoint,
            diameter: CreationStyle.activeHandleDiameter,
            fillColor: color,
            strokeColor: color
        )
    }

    private func drawCreationHandle(
        at point: CGPoint,
        diameter: CGFloat,
        fillColor: NSColor,
        strokeColor: NSColor
    ) {
        let handleRect = CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: handleRect)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = HandleStyle.strokeWidth
        path.stroke()
    }

    private func creationColor() -> NSColor {
        guard let label = defaultCreationLabel(),
              let color = labelColors[label] else {
            return CreationStyle.fallbackColor
        }

        return color
    }

    private func defaultCreationLabel() -> String? {
        let labels = annotation?.shapes.map { $0.label } ?? []
        if let lastCreatedLabel = lastCreatedLabel, labels.contains(lastCreatedLabel) {
            return lastCreatedLabel
        }

        return annotation?.shapes.last?.label
    }

    private func beginCreationDrag(at location: CGPoint) {
        window?.makeFirstResponder(self)
        guard let imagePoint = imagePoint(for: location) else { return }

        switch creationShapeKind {
        case .polygon:
            // 첫 드래그는 시작점을 만들고, 이후 드래그는 마지막 점에서 새 끝점으로 이어진다.
            if polygonCreationPoints.isEmpty {
                polygonCreationPoints = [imagePoint]
            }
            creationDragStartPoint = polygonCreationPoints.last
            creationDragCurrentPoint = imagePoint
            isCloseToFirstCreationPoint = false
        case .rectangle:
            creationDragStartPoint = imagePoint
            creationDragCurrentPoint = imagePoint
            isCloseToFirstCreationPoint = false
        }

        NSCursor.crosshair.set()
        needsDisplay = true
    }

    private func updateCreationDrag(at location: CGPoint) {
        guard let imagePoint = imagePoint(for: location) else { return }

        creationDragCurrentPoint = imagePoint
        if creationShapeKind == .polygon {
            // 첫 점 근처로 오면 mouseUp에서 polygon을 닫을 수 있도록 표시한다.
            isCloseToFirstCreationPoint = isNearFirstCreationPoint(location)
        }

        NSCursor.crosshair.set()
        needsDisplay = true
    }

    private func finishCreationDrag(at location: CGPoint) {
        switch creationShapeKind {
        case .polygon:
            finishPolygonCreationDrag(at: location)
        case .rectangle:
            finishRectangleCreationDrag(at: location)
        }

        NSCursor.crosshair.set()
    }

    private func finishPolygonCreationDrag(at location: CGPoint) {
        defer {
            creationDragStartPoint = nil
            creationDragCurrentPoint = nil
            isCloseToFirstCreationPoint = false
            needsDisplay = true
        }

        guard !polygonCreationPoints.isEmpty else { return }

        if polygonCreationPoints.count >= 3, isNearFirstCreationPoint(location) {
            // 세 점 이상 찍은 뒤 첫 점에서 놓으면 label 입력 후 polygon을 확정한다.
            commitCreatedShape(
                points: polygonCreationPoints.map { LabelMeAnnotation.Point(x: $0.x, y: $0.y) },
                shapeType: "polygon"
            )
            return
        }

        guard let imagePoint = imagePoint(for: location),
              let lastPoint = polygonCreationPoints.last,
              creationSegmentLength(from: lastPoint, to: imagePoint) >= CreationStyle.minimumSegmentLength else {
            return
        }

        // 아직 닫히지 않았다면 현재 드래그 끝점을 다음 꼭지점으로 추가한다.
        polygonCreationPoints.append(imagePoint)
    }

    private func finishRectangleCreationDrag(at location: CGPoint) {
        defer {
            creationDragStartPoint = nil
            creationDragCurrentPoint = nil
            needsDisplay = true
        }

        guard let startPoint = creationDragStartPoint,
              let endPoint = imagePoint(for: location),
              let rect = rectangleBounds(for: [startPoint, endPoint]) else {
            return
        }

        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        // 너무 작은 rectangle은 실수 드래그로 보고 생성하지 않는다.
        guard creationSegmentLength(from: topLeft, to: CGPoint(x: rect.maxX, y: rect.minY)) >= CreationStyle.minimumRectangleSide,
              creationSegmentLength(from: topLeft, to: CGPoint(x: rect.minX, y: rect.maxY)) >= CreationStyle.minimumRectangleSide else {
            return
        }

        commitCreatedShape(
            points: [
                LabelMeAnnotation.Point(x: topLeft.x, y: topLeft.y),
                LabelMeAnnotation.Point(x: bottomRight.x, y: bottomRight.y)
            ],
            shapeType: "rectangle"
        )
    }

    private func commitCreatedShape(points: [LabelMeAnnotation.Point], shapeType: String) {
        // 현재 이미지에 연결된 annotation이 없으면 저장할 대상이 없으므로 생성 확정을 중단한다.
        guard var annotation = annotation else { return }

        // label 입력 창에서 기존 label 목록을 보여주기 위해 현재 annotation의 label들을 넘긴다.
        let existingLabels = annotation.shapes.map { $0.label }
        // OK로 label이 확정된 경우에만 annotation에 새 shape를 추가한다.
        guard let label = onLabelRequested?(existingLabels)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            // Cancel을 누르거나 빈 label이면 화면에만 있던 임시 polygon/rectangle도 지운다.
            cancelCreation()
            return
        }

        // 새 label로 생성해도 현재 폴더 색상 set을 즉시 확장해 preview 색이 기본값으로 돌아가지 않게 한다.
        folderLabelColorPairs = LabelColorProvider.extending(folderLabelColorPairs, with: [label])
        // 다음 create 때 같은 class 색상과 label을 기본값으로 쓰기 위해 마지막 확정 label을 기억한다.
        lastCreatedLabel = label

        // 여기서 임시 도형이 실제 LabelMe shape 데이터가 된다.
        annotation.shapes.append(LabelMeAnnotation.Shape(label: label, points: points, shapeType: shapeType))

        // overlay의 annotation을 교체하면 화면 redraw와 labelColors 갱신이 didSet에서 함께 일어난다.
        self.annotation = annotation

        // 방금 추가한 shape는 기본적으로 오른쪽 Polygon Labels 체크 상태가 켜진 visible 상태여야 한다.
        visibleShapeIndexes.insert(annotation.shapes.count - 1)

        // 오른쪽 Polygon Labels 테이블이 새 annotation 기준으로 row를 다시 만들도록 알린다.
        onAnnotationChanged?(annotation)

        // 생성 완료 후에는 드래그 시작점, preview 선, close 상태 같은 임시 create 상태를 모두 초기화한다.
        cancelCreation()
    }

    private func cancelCreation() {
        // Esc, Cancel, 모드 전환 때 화면에만 있던 임시 생성 상태를 버린다.
        polygonCreationPoints = []
        creationDragStartPoint = nil
        creationDragCurrentPoint = nil
        isCloseToFirstCreationPoint = false
        needsDisplay = true
    }

    private func updateLabelColors() {
        let labels = annotation?.shapes.map { $0.label } ?? []
        labelColors = LabelColorProvider.colors(for: labels, preferredPairs: folderLabelColorPairs)
    }

    private func setCreationShapeKind(_ shapeKind: CreationShapeKind) {
        guard creationShapeKind != shapeKind else { return }
        // 생성 타입을 바꿀 때는 이전에 그리던 미완성 도형을 이어가지 않는다.
        creationShapeKind = shapeKind
        cancelCreation()
        NSCursor.crosshair.set()
    }

    private func isNearFirstCreationPoint(_ location: CGPoint) -> Bool {
        guard polygonCreationPoints.count >= 3,
              let firstPoint = polygonCreationPoints.first,
              let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return false
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        let firstViewPoint = viewPoint(for: firstPoint, imageRect: imageRect, imageSize: annotation.imageSize)
        // 화면상 첫 점 주변의 hit 영역으로 닫힘 여부를 판단한다.
        return distance(from: location, to: firstViewPoint) <= CreationStyle.closeHitDiameter / 2
    }

    private func creationSegmentLength(from startPoint: CGPoint, to endPoint: CGPoint) -> CGFloat {
        guard let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return 0
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        let startViewPoint = viewPoint(for: startPoint, imageRect: imageRect, imageSize: annotation.imageSize)
        let endViewPoint = viewPoint(for: endPoint, imageRect: imageRect, imageSize: annotation.imageSize)
        return distance(from: startViewPoint, to: endViewPoint)
    }

    private func distance(from firstPoint: CGPoint, to secondPoint: CGPoint) -> CGFloat {
        let deltaX = firstPoint.x - secondPoint.x
        let deltaY = firstPoint.y - secondPoint.y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    private func updateCursor(at location: CGPoint) {
        switch interactionMode {
        case .inactive:
            NSCursor.arrow.set()
        case .create:
            NSCursor.crosshair.set()
        case .edit:
            let newHoveredVertex = vertexSelection(at: location)
            let newHoveredShapeIndex = newHoveredVertex?.shapeIndex ?? shapeIndex(at: location)
            if newHoveredVertex != hoveredVertex || newHoveredShapeIndex != hoveredShapeIndex {
                hoveredVertex = newHoveredVertex
                hoveredShapeIndex = newHoveredShapeIndex
                needsDisplay = true
            }

            if newHoveredVertex != nil {
                NSCursor.pointingHand.set()
            } else if newHoveredShapeIndex != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private func vertexSelection(at location: CGPoint) -> VertexSelection? {
        guard interactionMode == .edit,
              let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return nil
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        for shapeIndex in annotation.shapes.indices.reversed() {
            guard visibleShapeIndexes.contains(shapeIndex) else { continue }

            let handles = handleViewPoints(
                for: annotation.shapes[shapeIndex],
                imageRect: imageRect,
                imageSize: annotation.imageSize
            )
            for vertexIndex in handles.indices.reversed() {
                let point = handles[vertexIndex]
                let hitRect = CGRect(
                    x: point.x - HandleStyle.hitDiameter / 2,
                    y: point.y - HandleStyle.hitDiameter / 2,
                    width: HandleStyle.hitDiameter,
                    height: HandleStyle.hitDiameter
                )
                if hitRect.contains(location) {
                    return VertexSelection(shapeIndex: shapeIndex, vertexIndex: vertexIndex)
                }
            }
        }

        return nil
    }

    private func handleViewPoints(
        for shape: LabelMeAnnotation.Shape,
        imageRect: CGRect,
        imageSize: NSSize
    ) -> [CGPoint] {
        return handleImagePoints(for: shape).map {
            viewPoint(for: $0, imageRect: imageRect, imageSize: imageSize)
        }
    }

    private func handleImagePoints(for shape: LabelMeAnnotation.Shape) -> [CGPoint] {
        if isRectangle(shape), let rect = rectangleBounds(for: shape.points.map({ CGPoint(x: $0.x, y: $0.y) })) {
            // rectangle은 LabelMe 저장 포맷과 맞춰 좌상단, 우하단 두 핸들만 편집한다.
            return [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY)
            ]
        }

        return shape.points.map { CGPoint(x: $0.x, y: $0.y) }
    }

    private func viewPoint(for imagePoint: CGPoint, imageRect: CGRect, imageSize: NSSize) -> CGPoint {
        return CGPoint(
            x: imageRect.minX + imagePoint.x * imageRect.width / imageSize.width,
            y: imageRect.minY + imagePoint.y * imageRect.height / imageSize.height
        )
    }

    private func updateRectangleCorner(
        in shape: inout LabelMeAnnotation.Shape,
        vertexIndex: Int,
        to point: CGPoint
    ) {
        guard let currentRect = rectangleBounds(for: shape.points.map({ CGPoint(x: $0.x, y: $0.y) })) else {
            return
        }

        let fixedPoint: CGPoint
        // rectangle 편집도 좌상단(index 0), 우하단(index 1) 두 점만 허용한다.
        switch vertexIndex {
        case 0:
            fixedPoint = CGPoint(x: currentRect.maxX, y: currentRect.maxY)
        case 1:
            fixedPoint = CGPoint(x: currentRect.minX, y: currentRect.minY)
        default:
            return
        }

        shape.points = [
            LabelMeAnnotation.Point(x: min(point.x, fixedPoint.x), y: min(point.y, fixedPoint.y)),
            LabelMeAnnotation.Point(x: max(point.x, fixedPoint.x), y: max(point.y, fixedPoint.y))
        ]
    }

    private func isRectangle(_ shape: LabelMeAnnotation.Shape) -> Bool {
        return shape.shapeType?.lowercased() == "rectangle"
    }

    private func rectangleBounds(for points: [CGPoint]) -> CGRect? {
        guard let firstPoint = points.first else { return nil }

        var minX = firstPoint.x
        var maxX = firstPoint.x
        var minY = firstPoint.y
        var maxY = firstPoint.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        guard maxX > minX, maxY > minY else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func rectangleBounds(for points: [LabelMeAnnotation.Point]) -> CGRect? {
        return rectangleBounds(for: points.map { CGPoint(x: $0.x, y: $0.y) })
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
        if isRectangle(shape), let rect = rectangleBounds(for: shape.points) {
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
