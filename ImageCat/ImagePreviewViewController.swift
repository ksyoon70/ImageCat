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

    // 오늘 수정: preview/annotation overlay가 first responder일 때 d 키 입력을 파일 리스트의 Next Image로 넘기기 위한 callback이다.
    // 실제 파일 선택은 ViewController가 담당하므로 preview는 이동 의도를 밖으로 알리기만 한다.
    var onSelectNextImage: (() -> Void)? {
        didSet {
            annotationOverlayView.onSelectNextImage = onSelectNextImage
        }
    }

    // 오늘 수정: a 키 입력도 같은 방식으로 이전 이미지 선택 요청만 전달한다.
    var onSelectPreviousImage: (() -> Void)? {
        didSet {
            annotationOverlayView.onSelectPreviousImage = onSelectPreviousImage
        }
    }

    // 오늘 수정: toolbar Zoom In/Out/Fit이 공유하는 배율 제한값이다.
    // zoomScale은 fit-to-view 배율 위에 곱해지는 사용자 배율이므로 1이 "화면에 맞춤" 상태다.
    private enum Zoom {
        static let minimumScale: CGFloat = 0.25
        static let maximumScale: CGFloat = 8
        static let step: CGFloat = 0.25
    }

    // 오늘 수정: 확대 시 이미지가 view bounds보다 커질 수 있으므로 NSImageView를 NSScrollView의 documentView 안에 둔다.
    // imageCanvasView는 imageView와 annotationOverlayView가 같은 확대/스크롤 좌표계를 공유하게 해주는 캔버스다.
    private let scrollView = PannableImageScrollView()
    private let imageCanvasView = ImageCanvasView()
    private let imageView = NonInteractiveImageView()
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
    // 오늘 수정 상세:
    // annotationOverlayView 안의 LabelMeAnnotation은 메모리에서 계속 수정된다.
    // 이 값이 true이면 아직 JSON 파일에 쓰지 않은 변경이 있다는 뜻이며,
    // 이미지 이동/폴더 이동 전에 자동저장 또는 저장 확인 alert를 띄우는 기준으로 사용한다.
    // load/save/delete label file이 끝나면 false로 돌린다.
    private var hasUnsavedAnnotationChanges = false
    // 오늘 수정: 1은 fit 상태, 1.25는 fit 크기의 125%, 8은 800%를 의미한다.
    private var zoomScale: CGFloat = 1
    // 오늘 수정: annotation imageSize 또는 실제 이미지 pixel size를 보관해 zoom/좌표 변환 기준으로 사용한다.
    private var currentDisplayImageSize: NSSize?
    // 오늘 수정: scroll document 좌표계 안에서 실제 이미지가 그려지는 rect다.
    // overlay hit-test와 drawing은 이 rect를 기준으로 image 좌표와 view 좌표를 변환한다.
    private var currentImageRect: CGRect = .zero
    
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

        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = imageCanvasView
        // 오늘 수정: inactive 모드에서는 overlay가 hitTest를 통과시키므로 canvas drag panning을 허용한다.
        // edit 모드에서는 overlay가 이벤트를 받기 때문에 overlay 내부에서 빈 공간 panning을 따로 처리한다.
        scrollView.allowsContentDragPanning = { [weak self] in
            guard let self else { return false }
            return self.annotationOverlayView.interactionMode == .inactive
        }
        // 오늘 수정 상세:
        // 트랙패드 pinch는 이벤트가 scrollView, canvas, overlay 중 어디로 들어오느냐가 모드마다 다르다.
        // inactive 모드에서는 canvas/scrollView가 받을 수 있고, edit 모드에서는 overlay가 hit-test를 잡는다.
        // 세 view 모두 같은 magnify callback을 공유하게 해서 어떤 모드에서도 같은 zoomScale 경로를 탄다.
        scrollView.onMagnify = { [weak self] event in
            self?.magnifyImage(with: event)
        }
        imageCanvasView.onMagnify = { [weak self] event in
            self?.magnifyImage(with: event)
        }
        annotationOverlayView.onMagnify = { [weak self] event in
            self?.magnifyImage(with: event)
        }

        // 오늘 수정: zoom layout이 imageView.frame을 직접 계산하므로 AppKit 비율 맞춤 scaling 대신
        // 주어진 frame에 이미지를 정확히 채우는 scaling을 쓴다.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // 새 도형이 추가되면 오른쪽 라벨 목록도 즉시 최신 annotation 기준으로 갱신한다.
        annotationOverlayView.onAnnotationChanged = { [weak self] annotation in
            // 오늘 수정 상세:
            // shape 추가/삭제/붙여넣기/점 편집/드래그 종료처럼 annotation 내용이 실제로 바뀐 경우
            // overlay가 이 callback을 호출한다. 여기서 dirty flag를 세워 저장 확인 로직과 연결한다.
            self?.hasUnsavedAnnotationChanges = true
            self?.imageControlViewController?.updatePolygonLabels(from: annotation)
        }
        // 오늘 수정: preview에서 객체를 클릭하면 오른쪽 Polygon Labels table도 같은 shape row를 선택하게 한다.
        annotationOverlayView.onSelectedShapeChanged = { [weak self] shapeIndexes in
            self?.imageControlViewController?.selectPolygonLabelRows(forShapeIndexes: shapeIndexes)
        }
        // 오버레이는 화면 입력만 담당하고, label 입력은 Storyboard 다이얼로그에 위임한다.
        annotationOverlayView.onLabelRequested = { [weak self] labels in
            self?.requestAnnotationLabel(existingLabels: labels)
        }
        annotationOverlayView.onPanDragChanged = { [weak self] lastLocation, currentLocation in
            self?.panScrollView(from: lastLocation, to: currentLocation)
        }
        // 오늘 수정: overlay가 first responder인 동안 a/d 이미지 이동 단축키를 window/file list 쪽으로 전달한다.
        annotationOverlayView.onSelectNextImage = onSelectNextImage
        annotationOverlayView.onSelectPreviousImage = onSelectPreviousImage

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // 오늘 수정: 이미지와 annotation overlay를 같은 documentView 안에 두어
        // scroll/zoom 후에도 polygon 좌표가 이미지 위에 정확히 겹치도록 한다.
        imageCanvasView.addSubview(imageView)
        imageCanvasView.addSubview(annotationOverlayView)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateZoomLayout(preservingVisibleImageCenter: true)
    }

    private func updateImage() {
        guard isViewLoaded else { return }

        // 오늘 수정: 이미지 파일이 바뀌면 curve control은 항상 기본 직선 상태로 돌아가야 한다.
        // preview는 아래에서 새 원본 이미지를 직접 넣으므로 curve reset은 중복 렌더 없이 조용히 수행한다.
        imageControlViewController?.resetCurveForImageSelection()

        guard let imageURL = imageURL, let image = NSImage(contentsOf: imageURL) else {
            renderGeneration += 1
            originalImage = nil
            pendingRenderRequest = nil
            imageView.image = nil
            // 오늘 수정: 이미지가 없는 상태에서는 zoom/표시 rect를 모두 초기화해 이전 이미지의 scroll 좌표가 남지 않게 한다.
            zoomScale = 1
            currentDisplayImageSize = nil
            currentImageRect = .zero
            updateZoomLayout(preservingVisibleImageCenter: false)
            // 오늘 수정: 새 이미지 로드/해제 시 overlay undo stack과 selection도 함께 비우기 위해 loadAnnotation을 사용한다.
            annotationOverlayView.loadAnnotation(nil)
            annotationOverlayView.displayedImageRect = .zero
            annotationOverlayView.visibleShapeIndexes = []
            hasUnsavedAnnotationChanges = false
            imageControlViewController?.updatePolygonLabels(from: nil)
            emptyLabel.isHidden = false
            return
        }

        renderGeneration += 1
        originalImage = image
        // 오늘 수정: 새 이미지를 선택할 때마다 fit 상태에서 시작한다.
        zoomScale = 1
        pendingRenderRequest = nil
        imageView.image = image

        let annotation = Self.loadAnnotation(
            for: imageURL,
            fallbackImageSize: image.pixelSizeForPreviewRendering()
        )
        // 오늘 수정: JSON annotation이 있으면 LabelMe의 imageWidth/imageHeight를 우선 사용한다.
        // JSON이 없는 이미지도 새 annotation을 만들 수 있도록 실제 pixel size를 fallback으로 쓴다.
        currentDisplayImageSize = annotation?.imageSize ?? image.pixelSizeForPreviewRendering() ?? image.size

        // 오늘 수정: annotation 교체 시 undo history와 선택 상태가 이전 이미지에서 이어지면 안 되므로 loadAnnotation으로 교체한다.
        annotationOverlayView.loadAnnotation(annotation)
        hasUnsavedAnnotationChanges = false
        imageControlViewController?.updatePolygonLabels(from: annotation)
        updateZoomLayout(preservingVisibleImageCenter: false)

        emptyLabel.isHidden = true
    }

    private func setZoomScale(
        _ newScale: CGFloat,
        preservingVisibleImageCenter: Bool = true
    ) {
        // 오늘 수정: toolbar 반복 클릭으로 배율이 최소/최대 범위를 넘어가지 않도록 clamp한다.
        let clampedScale = min(Zoom.maximumScale, max(Zoom.minimumScale, newScale))
        guard abs(zoomScale - clampedScale) > 0.0001 else { return }

        zoomScale = clampedScale
        updateZoomLayout(preservingVisibleImageCenter: preservingVisibleImageCenter)
    }

    private func magnifyImage(with event: NSEvent) {
        // 오늘 수정 상세:
        // NSEvent.magnification은 pinch gesture의 "이번 이벤트 변화량"이다.
        // 기존 toolbar zoom과 같은 zoomScale을 곱해서 사용해야 버튼 zoom, fit, scroll layout과 충돌하지 않는다.
        // setZoomScale 내부에서 최소/최대 배율 clamp와 visible center 유지가 처리된다.
        guard currentDisplayImageSize != nil else { return }

        let scaleFactor = max(0.1, 1 + event.magnification)
        setZoomScale(zoomScale * scaleFactor)
        view.window?.toolbar?.validateVisibleItems()
    }

    private func updateZoomLayout(preservingVisibleImageCenter: Bool) {
        guard isViewLoaded,
              let imageSize = currentDisplayImageSize,
              imageSize.width > 0,
              imageSize.height > 0 else {
            // 오늘 수정: 이미지가 없을 때도 scrollView documentView가 안정적인 크기를 갖도록 clip bounds에 맞춘다.
            imageCanvasView.frame = scrollView.contentView.bounds
            imageView.frame = .zero
            annotationOverlayView.frame = imageCanvasView.bounds
            annotationOverlayView.displayedImageRect = .zero
            currentImageRect = .zero
            return
        }

        // 오늘 수정: zoom 전후에도 사용자가 보고 있던 이미지 중심을 최대한 유지하기 위해
        // visible center를 이미지 내부 비율(0...1)로 저장했다가 새 layout에 다시 적용한다.
        let centerRatio = preservingVisibleImageCenter ? visibleImageCenterRatio() : CGPoint(x: 0.5, y: 0.5)
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0, clipSize.height > 0 else { return }

        // 오늘 수정: fitScale은 "이미지 전체가 scrollView 안에 들어오는" 기본 배율이고,
        // zoomScale은 toolbar가 바꾸는 사용자 배율이다.
        let fitScale = min(clipSize.width / imageSize.width, clipSize.height / imageSize.height)
        let displayScale = fitScale * zoomScale
        let displayedImageSize = CGSize(
            width: max(1, imageSize.width * displayScale),
            height: max(1, imageSize.height * displayScale)
        )
        // 오늘 수정: zoom out 상태에서도 documentView가 clip보다 작아지지 않게 해 이미지가 중앙에 위치하도록 한다.
        // zoom in으로 이미지가 clip보다 커지면 documentView도 커져서 scroller가 나타난다.
        let documentSize = CGSize(
            width: max(clipSize.width, displayedImageSize.width),
            height: max(clipSize.height, displayedImageSize.height)
        )
        let imageRect = CGRect(
            x: (documentSize.width - displayedImageSize.width) / 2,
            y: (documentSize.height - displayedImageSize.height) / 2,
            width: displayedImageSize.width,
            height: displayedImageSize.height
        )

        imageCanvasView.setFrameSize(documentSize)
        imageView.frame = imageRect
        // 오늘 수정: overlay frame은 document 전체이고, 실제 이미지 위치는 displayedImageRect로 전달한다.
        // 이렇게 해야 검은 여백을 포함한 scroll 영역에서도 polygon hit-test는 이미지 영역만 기준으로 동작한다.
        annotationOverlayView.frame = CGRect(origin: .zero, size: documentSize)
        annotationOverlayView.displayedImageRect = imageRect
        currentImageRect = imageRect

        scrollToImageCenterRatio(centerRatio)
    }

    private func visibleImageCenterRatio() -> CGPoint? {
        guard currentImageRect.width > 0, currentImageRect.height > 0 else { return nil }

        let visibleRect = scrollView.contentView.bounds
        let visibleCenter = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        return CGPoint(
            x: min(1, max(0, (visibleCenter.x - currentImageRect.minX) / currentImageRect.width)),
            y: min(1, max(0, (visibleCenter.y - currentImageRect.minY) / currentImageRect.height))
        )
    }

    private func scrollToImageCenterRatio(_ centerRatio: CGPoint?) {
        guard let centerRatio else { return }

        let clipSize = scrollView.contentView.bounds.size
        let documentSize = imageCanvasView.bounds.size
        let targetCenter = CGPoint(
            x: currentImageRect.minX + currentImageRect.width * centerRatio.x,
            y: currentImageRect.minY + currentImageRect.height * centerRatio.y
        )
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let origin = CGPoint(
            x: min(maxOrigin.x, max(0, targetCenter.x - clipSize.width / 2)),
            y: min(maxOrigin.y, max(0, targetCenter.y - clipSize.height / 2))
        )

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func panScrollView(from lastLocationInWindow: CGPoint, to currentLocationInWindow: CGPoint) {
        // 오늘 수정: mouse drag delta를 scroll origin delta로 바꾼다.
        // AppKit의 flipped 좌표계 때문에 x/y 방향을 각각 현재 documentView 움직임에 맞게 계산한다.
        let delta = CGPoint(
            x: lastLocationInWindow.x - currentLocationInWindow.x,
            y: currentLocationInWindow.y - lastLocationInWindow.y
        )
        let clipSize = scrollView.contentView.bounds.size
        let documentSize = imageCanvasView.bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let currentOrigin = scrollView.contentView.bounds.origin
        // 오늘 수정: drag로 scroll할 때 document bounds 밖으로 나가지 않도록 origin을 0...maxOrigin으로 clamp한다.
        let origin = CGPoint(
            x: min(maxOrigin.x, max(0, currentOrigin.x + delta.x)),
            y: min(maxOrigin.y, max(0, currentOrigin.y + delta.y))
        )

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func setVisibleAnnotationShapeIndexes(_ indexes: Set<Int>) {
        annotationOverlayView.visibleShapeIndexes = indexes
    }

    func selectAnnotationShape(at shapeIndex: Int?, notifiesSelectionChange: Bool = true) {
        annotationOverlayView.selectShape(at: shapeIndex, notifiesSelectionChange: notifiesSelectionChange)
    }

    func selectAnnotationShapes(at shapeIndexes: Set<Int>, notifiesSelectionChange: Bool = true) {
        annotationOverlayView.selectShapes(at: shapeIndexes, notifiesSelectionChange: notifiesSelectionChange)
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

    var canZoomIn: Bool {
        return currentDisplayImageSize != nil && zoomScale < Zoom.maximumScale
    }

    var canZoomOut: Bool {
        return currentDisplayImageSize != nil && zoomScale > Zoom.minimumScale
    }

    var canFitImage: Bool {
        return currentDisplayImageSize != nil
    }

    func zoomIn() {
        setZoomScale(min(Zoom.maximumScale, zoomScale + Zoom.step))
    }

    func zoomOut() {
        setZoomScale(max(Zoom.minimumScale, zoomScale - Zoom.step))
    }

    func fitImage() {
        setZoomScale(1, preservingVisibleImageCenter: false)
    }

    var selectedAnnotationShapeIndexes: Set<Int> {
        return annotationOverlayView.selectedAnnotationShapeIndexes
    }

    var hasUnsavedAnnotationEdits: Bool {
        return hasUnsavedAnnotationChanges
    }

    @discardableResult
    func deleteSelectedAnnotationShape() -> Bool {
        // 오늘 수정: WindowController가 private overlay에 직접 접근하지 않도록 공개 wrapper를 둔다.
        return annotationOverlayView.deleteSelectedShape()
    }

    @discardableResult
    func deleteCurrentAnnotationFile() throws -> Bool {
        // 오늘 수정 상세:
        // toolbar Delete File 요청은 실제 이미지 파일 삭제가 아니라 현재 이미지에 딸린 LabelMe JSON 삭제다.
        // JSON을 지운 뒤 preview에는 같은 이미지 크기의 빈 annotation을 다시 로드해
        // 오른쪽 Polygon Labels와 overlay 선택 상태가 삭제된 파일 상태와 일치하도록 만든다.
        guard let imageURL else {
            throw AnnotationSaveError.missingImage
        }

        let jsonURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            try FileManager.default.removeItem(at: jsonURL)
        }

        let imageSize = currentDisplayImageSize ?? .zero
        let emptyAnnotation = LabelMeAnnotation(
            shapes: [],
            imageHeight: imageSize.height,
            imageWidth: imageSize.width
        )
        annotationOverlayView.loadAnnotation(emptyAnnotation)
        hasUnsavedAnnotationChanges = false
        imageControlViewController?.updatePolygonLabels(from: emptyAnnotation)
        return true
    }

    func saveCurrentAnnotation() throws {
        // 오늘 수정 상세:
        // JSON 파일이 없더라도 saveAnnotation(_:for:)가 새 root dictionary를 만들어
        // 현재 이미지 basename.json 파일을 생성한다. 저장 성공 후에는 dirty flag를 false로 만든다.
        guard let imageURL else {
            throw AnnotationSaveError.missingImage
        }

        guard let annotation = annotationOverlayView.annotation else {
            throw AnnotationSaveError.missingAnnotation
        }

        try Self.saveAnnotation(annotation, for: imageURL)
        hasUnsavedAnnotationChanges = false
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
            updateZoomLayout(preservingVisibleImageCenter: true)
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
                    self.updateZoomLayout(preservingVisibleImageCenter: true)
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
        // 오늘 수정: 코드로 조립하던 NSAlert 대신 Storyboard 다이얼로그를 사용한다.
        // 매번 새로 생성해야 이전 입력 상태와 table selection이 남지 않는다.
        let storyboard = NSStoryboard(name: NSStoryboard.Name("Main"), bundle: .main)
        guard let prompt = storyboard.instantiateController(
            withIdentifier: NSStoryboard.SceneIdentifier("AnnotationLabelPromptWindowController")
        ) as? AnnotationLabelPromptWindowController else {
            return nil
        }

        // 생성 동작이 끝난 직후의 마우스 화면 좌표 근처에 다이얼로그를 표시한다.
        return prompt.runModal(
            near: NSEvent.mouseLocation,
            parent: view.window,
            existingLabels: existingLabels
        )
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

private final class NonInteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 오늘 수정: 이미지 자체가 mouse event를 먹으면 overlay/canvas가 drag와 edit 이벤트를 받을 수 없다.
        // NSImageView는 표시만 담당하게 하고 hit-test는 항상 뒤쪽 view로 넘긴다.
        return nil
    }
}

private final class ImageCanvasView: NSView {
    // 오늘 수정: inactive 모드에서 이미지 빈 공간을 드래그하면 scroll panning처럼 동작하게 하기 위한 callback이다.
    // edit 모드 panning은 overlay가 이벤트를 잡기 때문에 AnnotationOverlayView에서 별도로 처리한다.
    var allowsDragPanning: (() -> Bool)?
    var onMagnify: ((NSEvent) -> Void)?
    weak var scrollView: NSScrollView?
    private var lastDragLocationInWindow: CGPoint?

    override var isFlipped: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsDragPanning?() == true else {
            super.mouseDown(with: event)
            return
        }

        lastDragLocationInWindow = event.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView,
              let lastDragLocationInWindow,
              allowsDragPanning?() == true else {
            super.mouseDragged(with: event)
            return
        }

        // 오늘 수정: documentView를 직접 드래그하듯 보이도록 mouse delta를 clipView origin delta로 바꾼다.
        let currentLocationInWindow = event.locationInWindow
        let delta = CGPoint(
            x: lastDragLocationInWindow.x - currentLocationInWindow.x,
            y: currentLocationInWindow.y - lastDragLocationInWindow.y
        )
        let clipSize = scrollView.contentView.bounds.size
        let documentSize = bounds.size
        let maxOrigin = CGPoint(
            x: max(0, documentSize.width - clipSize.width),
            y: max(0, documentSize.height - clipSize.height)
        )
        let currentOrigin = scrollView.contentView.bounds.origin
        let origin = CGPoint(
            x: min(maxOrigin.x, max(0, currentOrigin.x + delta.x)),
            y: min(maxOrigin.y, max(0, currentOrigin.y + delta.y))
        )

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        self.lastDragLocationInWindow = currentLocationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        lastDragLocationInWindow = nil
        NSCursor.arrow.set()
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }
}

private final class PannableImageScrollView: NSScrollView {
    var onMagnify: ((NSEvent) -> Void)?

    var allowsContentDragPanning: (() -> Bool)? {
        didSet {
            // 오늘 수정: scrollView가 documentView를 갖기 전/후 어느 시점에 설정돼도 canvas가 같은 callback을 받도록 전달한다.
            (documentView as? ImageCanvasView)?.allowsDragPanning = allowsContentDragPanning
        }
    }

    override var documentView: NSView? {
        didSet {
            if let canvasView = documentView as? ImageCanvasView {
                // 오늘 수정: canvas는 실제 scroll origin을 바꾸기 위해 자신을 감싸는 scrollView를 알아야 한다.
                canvasView.scrollView = self
                canvasView.allowsDragPanning = allowsContentDragPanning
            }
        }
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }
}

private final class AnnotationOverlayView: NSView {
    // 오늘 수정 상세:
    // 이미지 간 객체 복사를 위해 앱 실행 중 공유되는 임시 clipboard다.
    // NSPasteboard가 아니라 앱 내부 static 저장소를 쓰는 이유는 LabelMeAnnotation.Shape 값을
    // label/points/shape_type 그대로 보관하면 다른 이미지로 이동해도 손실 없이 붙여넣을 수 있기 때문이다.
    // 앱을 종료하면 사라지는 임시 상태이며, 시스템 clipboard에는 영향을 주지 않는다.
    private static var copiedShapes: [LabelMeAnnotation.Shape] = []

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

    private struct SegmentSelection {
        let shapeIndex: Int
        let insertIndex: Int
        let imagePoint: CGPoint
    }

    // 오늘 수정: AppKit UndoManager 대신 overlay 내부에서 annotation 편집 전 상태를 저장한다.
    // 점 이동/점 추가/점 삭제/polygon 삭제 직전에 snapshot을 쌓고 Cmd+Z 또는 context menu Undo에서 복원한다.
    private struct AnnotationSnapshot {
        let annotation: LabelMeAnnotation
        let visibleShapeIndexes: Set<Int>
        let selectedShapeIndex: Int?
        let selectedShapeIndexes: Set<Int>
        let selectedVertex: VertexSelection?
    }

    var annotation: LabelMeAnnotation? = nil {
        didSet {
            let labels = annotation?.shapes.map { $0.label } ?? []
            updateLabelColors()
            if let lastCreatedLabel = lastCreatedLabel, !labels.contains(lastCreatedLabel) {
                self.lastCreatedLabel = nil
            }
            // 오늘 수정: 삭제/교체 후 선택 index가 annotation 범위를 벗어나면 선택을 해제한다.
            if let selectedShapeIndex, annotation?.shapes.indices.contains(selectedShapeIndex) != true {
                self.selectedShapeIndex = nil
            }
            selectedShapeIndexes = Set(selectedShapeIndexes.filter { annotation?.shapes.indices.contains($0) == true })
            if let selectedVertex, !isValidVertexSelection(selectedVertex, in: annotation) {
                self.selectedVertex = nil
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

    var displayedImageRect: CGRect = .zero {
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
    // 오늘 수정: toolbar 버튼을 누르러 마우스가 떠나도 edit 선택 shape를 유지하기 위한 상태다.
    // 오늘 수정 상세:
    // selectedShapeIndex는 기존 삭제/꼭지점 편집 코드가 기대하는 "대표 선택"이다.
    // selectedShapeIndexes는 table 다중 선택과 Cmd-click 다중 선택을 표현하는 실제 선택 집합이다.
    // 다중 선택 상태에서도 vertex 편집/삭제 같은 기존 단일 대상 작업은 selectedShapeIndex를 기준으로 동작한다.
    private var selectedShapeIndex: Int?
    private var selectedShapeIndexes: Set<Int> = []
    // 오늘 수정: context menu의 "Remove Selected Point"와 선택 꼭지점 강조를 위해 shape뿐 아니라 vertex까지 따로 저장한다.
    private var selectedVertex: VertexSelection?
    private var hoveredShapeIndex: Int?
    private var hoveredVertex: VertexSelection?
    private var draggingVertex: VertexSelection?
    // 꼭지점이 아닌 도형 내부를 잡았을 때 전체 shape를 이동하기 위한 drag 상태다.
    private var draggingShapeIndex: Int?
    private var shapeDragLastImagePoint: CGPoint?
    // 오늘 수정: edit 모드에서 빈 공간을 드래그하면 도형 편집이 아니라 scroll panning을 수행하기 위한 상태다.
    private var isPanningImage = false
    private var panDragLastLocationInWindow: CGPoint?
    private var creationShapeKind: CreationShapeKind = .polygon
    private var polygonCreationPoints: [CGPoint] = []
    private var creationDragStartPoint: CGPoint?
    private var creationDragCurrentPoint: CGPoint?
    private var isCloseToFirstCreationPoint = false
    private var lastCreatedLabel: String?
    // 오늘 수정: 최근 annotation 편집 상태를 최대 50개까지 보관해 Cmd+Z/context menu Undo를 지원한다.
    private var undoSnapshots: [AnnotationSnapshot] = []
    // 오늘 수정: vertex/shape drag는 mouseDragged가 여러 번 호출되므로 한 drag gesture당 undo snapshot은 한 번만 쌓는다.
    private var hasPushedUndoForCurrentDrag = false
    // 생성 확정과 label 입력은 상위 컨트롤러와 협력해서 처리한다.
    var onAnnotationChanged: ((LabelMeAnnotation?) -> Void)?
    // 오늘 수정: preview 객체 선택과 오른쪽 Polygon Labels table 선택을 양방향으로 맞추기 위한 callback이다.
    var onSelectedShapeChanged: ((Set<Int>) -> Void)?
    var onLabelRequested: (([String]) -> String?)?
    var onPanDragChanged: ((CGPoint, CGPoint) -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    // 오늘 수정: overlay가 first responder일 때 a/d 키 입력을 파일 리스트 이미지 이동으로 넘기기 위한 callback이다.
    var onSelectNextImage: (() -> Void)?
    var onSelectPreviousImage: (() -> Void)?

    var interactionMode: PolygonInteractionMode = .edit {
        didSet {
            guard oldValue != interactionMode else { return }
            // 모드가 바뀌면 선택 핸들과 작성 중인 임시 도형을 모두 정리한다.
            // 오늘 수정: edit 선택은 모드가 바뀌면 더 이상 유효하지 않으므로 함께 초기화한다.
            selectedShapeIndex = nil
            selectedShapeIndexes = []
            selectedVertex = nil
            hoveredShapeIndex = nil
            hoveredVertex = nil
            draggingVertex = nil
            draggingShapeIndex = nil
            shapeDragLastImagePoint = nil
            isPanningImage = false
            panDragLastLocationInWindow = nil
            hasPushedUndoForCurrentDrag = false
            cancelCreation()
            if interactionMode == .create {
                // create 모드는 항상 polygon 생성에서 시작한다.
                creationShapeKind = .polygon
            }
            if interactionMode == .create || interactionMode == .edit {
                // create/edit 모드는 overlay가 단축키와 메뉴 action을 받도록 first responder를 가져온다.
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

    var selectedAnnotationShapeIndexes: Set<Int> {
        return selectedShapeIndexes
    }

    func loadAnnotation(_ annotation: LabelMeAnnotation?) {
        // 오늘 수정: 새 이미지/annotation으로 교체할 때 이전 이미지의 undo history, 선택, drag 상태를 모두 버린다.
        // 그렇지 않으면 Cmd+Z가 이전 파일의 polygon 상태를 현재 파일에 적용할 수 있다.
        undoSnapshots.removeAll()
        selectedShapeIndex = nil
        selectedShapeIndexes = []
        selectedVertex = nil
        hoveredShapeIndex = nil
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        hasPushedUndoForCurrentDrag = false
        visibleShapeIndexes = []
        self.annotation = annotation
        notifySelectedShapeChanged()
    }

    func selectShape(at shapeIndex: Int?, notifiesSelectionChange: Bool = true) {
        guard let shapeIndex else {
            // 오늘 수정: Polygon Labels table에서 선택이 해제되면 preview 선택도 같이 해제한다.
            selectedShapeIndex = nil
            selectedShapeIndexes = []
            selectedVertex = nil
            hoveredShapeIndex = nil
            hoveredVertex = nil
            draggingVertex = nil
            draggingShapeIndex = nil
            shapeDragLastImagePoint = nil
            if notifiesSelectionChange {
                notifySelectedShapeChanged()
            }
            needsDisplay = true
            return
        }

        guard annotation?.shapes.indices.contains(shapeIndex) == true else { return }

        // 오늘 수정: Polygon Labels row를 클릭한 경우 shape 전체 선택만 수행하고 vertex 선택은 비운다.
        // 이 상태에서는 Delete Polygons와 shape 강조가 동작하고, 꼭지점 전용 메뉴는 뜨지 않는다.
        selectedShapeIndex = shapeIndex
        selectedShapeIndexes = [shapeIndex]
        selectedVertex = nil
        hoveredShapeIndex = shapeIndex
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        if notifiesSelectionChange {
            notifySelectedShapeChanged()
        }
        needsDisplay = true
    }

    func selectShapes(at shapeIndexes: Set<Int>, notifiesSelectionChange: Bool = true) {
        // 오늘 수정 상세:
        // Polygon Labels table에서 여러 row가 선택되면 shape index Set으로 이 함수에 들어온다.
        // annotation이 바뀐 직후 오래된 index가 섞일 수 있으므로 현재 shapes 범위에 있는 index만 남긴다.
        // notifiesSelectionChange=false는 table -> preview 동기화 중 다시 preview -> table 콜백이 도는 것을 막기 위한 옵션이다.
        let validShapeIndexes = Set(shapeIndexes.filter {
            annotation?.shapes.indices.contains($0) == true
        })

        guard !validShapeIndexes.isEmpty else {
            selectShape(at: nil, notifiesSelectionChange: notifiesSelectionChange)
            return
        }

        selectedShapeIndexes = validShapeIndexes
        selectedShapeIndex = validShapeIndexes.sorted().first
        selectedVertex = nil
        hoveredShapeIndex = selectedShapeIndex
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        if notifiesSelectionChange {
            notifySelectedShapeChanged()
        }
        needsDisplay = true
    }

    private func toggleShapeSelection(at location: CGPoint) {
        // 오늘 수정 상세:
        // edit 모드에서 Cmd-click한 객체를 선택 Set에 추가하거나 제거한다.
        // 일반 click은 기존처럼 단일 선택/drag/vertex 편집을 시작하지만,
        // Cmd-click은 다중 선택 토글 전용이라 drag 상태를 만들지 않고 바로 반환한다.
        guard let shapeIndex = shapeIndex(at: location) else { return }

        if selectedShapeIndexes.contains(shapeIndex) {
            selectedShapeIndexes.remove(shapeIndex)
            if selectedShapeIndex == shapeIndex {
                selectedShapeIndex = selectedShapeIndexes.sorted().first
            }
        } else {
            selectedShapeIndexes.insert(shapeIndex)
            selectedShapeIndex = shapeIndex
        }

        selectedVertex = nil
        hoveredShapeIndex = selectedShapeIndex
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        isPanningImage = false
        panDragLastLocationInWindow = nil
        notifySelectedShapeChanged()
        needsDisplay = true
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
        if draggingVertex != nil || draggingShapeIndex != nil || isPanningImage {
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            // 오늘 수정 상세:
            // Cmd-click을 먼저 처리해야 polygon 내부 클릭이 shape 이동 drag로 해석되지 않는다.
            // 따라서 vertex hit-test나 segment insertion보다 앞에서 다중 선택 토글을 끝낸다.
            toggleShapeSelection(at: location)
            return
        }

        var selectedVertex = vertexSelection(at: location)
        // 오늘 수정: 꼭지점이 아니라 polygon 선분을 클릭한 경우 새 꼭지점을 삽입하고
        // 방금 삽입한 점을 즉시 draggingVertex로 잡아 이어서 드래그 편집할 수 있게 한다.
        if selectedVertex == nil, let selectedSegment = segmentSelection(at: location) {
            selectedVertex = insertVertex(at: selectedSegment)
        }
        let selectedShapeIndex = selectedVertex?.shapeIndex ?? shapeIndex(at: location)
        draggingVertex = selectedVertex
        // 꼭지점을 잡은 경우에는 vertex resize가 우선이고, 내부를 잡은 경우에만 shape 이동을 시작한다.
        draggingShapeIndex = selectedVertex == nil ? selectedShapeIndex : nil
        shapeDragLastImagePoint = draggingShapeIndex == nil ? nil : imagePoint(for: location)
        hasPushedUndoForCurrentDrag = false
        self.selectedVertex = selectedVertex
        hoveredVertex = selectedVertex
        hoveredShapeIndex = selectedShapeIndex
        // 오늘 수정: 클릭한 shape를 hover와 별도로 저장해서 Delete Polygons 버튼이 사용할 수 있게 한다.
        self.selectedShapeIndex = selectedShapeIndex
        selectedShapeIndexes = selectedShapeIndex.map { Set([$0]) } ?? []
        // 오늘 수정: preview에서 객체를 클릭했으므로 오른쪽 Polygon Labels table selection도 같은 shape로 맞춘다.
        notifySelectedShapeChanged()

        if selectedVertex != nil {
            NSCursor.pointingHand.set()
        } else if draggingShapeIndex != nil {
            NSCursor.closedHand.set()
        } else {
            // 오늘 수정: edit 모드에서 빈 공간을 드래그하면 확대된 이미지를 scroll panning한다.
            // shape/vertex/segment가 잡히지 않은 클릭만 panning으로 처리해 도형 편집과 충돌하지 않게 한다.
            isPanningImage = true
            panDragLastLocationInWindow = event.locationInWindow
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

        if isPanningImage {
            // 오늘 수정: overlay가 이벤트를 잡는 edit 모드에서는 canvas가 mouseDragged를 받을 수 없으므로
            // overlay가 window 좌표 delta만 상위 preview controller에 전달해 scrollView를 움직인다.
            let currentLocationInWindow = event.locationInWindow
            if let panDragLastLocationInWindow {
                onPanDragChanged?(panDragLastLocationInWindow, currentLocationInWindow)
            }
            self.panDragLastLocationInWindow = currentLocationInWindow
            NSCursor.closedHand.set()
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard let currentImagePoint = imagePoint(for: location) else { return }

        if let draggingVertex = draggingVertex {
            guard var annotation = annotation,
                  annotation.shapes.indices.contains(draggingVertex.shapeIndex) else {
                return
            }

            // 오늘 수정: 꼭지점 drag가 시작된 첫 mouseDragged에서만 이전 annotation을 undo stack에 저장한다.
            pushUndoSnapshotForCurrentDragIfNeeded()
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
            selectedVertex = draggingVertex
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

            // 오늘 수정: shape 전체 이동도 한 drag gesture당 undo snapshot을 한 번만 저장한다.
            pushUndoSnapshotForCurrentDragIfNeeded()
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
        isPanningImage = false
        panDragLastLocationInWindow = nil
        if hasPushedUndoForCurrentDrag, let annotation {
            // 오늘 수정 상세:
            // drag 중에는 mouseDragged가 매우 자주 호출되므로 매 프레임 table reload/dirty callback을 보내지 않는다.
            // 대신 drag가 실제 편집을 시작해 undo snapshot을 쌓은 경우에만 mouseUp에서 한 번 callback을 보내
            // 자동저장 dirty 상태와 Polygon Labels 목록을 최신으로 맞춘다.
            onAnnotationChanged?(annotation)
        }
        hasPushedUndoForCurrentDrag = false

        let location = convert(event.locationInWindow, from: nil)
        updateCursor(at: location)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard interactionMode == .edit else {
            super.rightMouseDown(with: event)
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        if let clickedVertex = vertexSelection(at: location) {
            // 오늘 수정: 오른쪽 클릭한 위치가 꼭지점이면 그 꼭지점을 현재 선택으로 만든 뒤 메뉴를 띄운다.
            // 이미 선택된 꼭지점이 있다면 꼭지점 위가 아닌 곳에서 우클릭해도 아래 guard를 통해 기존 선택 메뉴를 띄울 수 있다.
            selectedVertex = clickedVertex
            selectedShapeIndex = clickedVertex.shapeIndex
            selectedShapeIndexes = [clickedVertex.shapeIndex]
            hoveredVertex = clickedVertex
            hoveredShapeIndex = clickedVertex.shapeIndex
            notifySelectedShapeChanged()
            needsDisplay = true
        }

        guard let selectedVertex,
              isValidVertexSelection(selectedVertex, in: annotation) else {
            super.rightMouseDown(with: event)
            return
        }

        showVertexContextMenu(for: selectedVertex)
    }

    override func keyDown(with event: NSEvent) {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 오늘 수정: overlay가 first responder인 동안에도 a/d를 이미지 이동 단축키로 사용한다.
        // modifier가 붙은 입력은 create/edit 단축키나 AppKit 기본 처리로 넘긴다.
        if modifierFlags.isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "d":
                onSelectNextImage?()
                return
            case "a":
                onSelectPreviousImage?()
                return
            default:
                break
            }
        }

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

    @objc private func deletePolygonFromContextMenu(_ sender: NSMenuItem) {
        deleteSelectedShape()
    }

    @objc private func undoAnnotationEditFromContextMenu(_ sender: NSMenuItem) {
        undoLastAnnotationEdit()
    }

    @objc private func removeSelectedPointFromContextMenu(_ sender: NSMenuItem) {
        removeSelectedPoint()
    }

    @objc func undo(_ sender: Any?) {
        // 오늘 수정: 메뉴바 Edit > Undo가 first responder의 undo:로 들어오므로
        // edit 모드일 때 overlay undo stack을 복원한다.
        guard interactionMode == .edit else { return }
        undoLastAnnotationEdit()
    }

    @objc func copy(_ sender: Any?) {
        copySelectedShapes()
    }

    @objc func paste(_ sender: Any?) {
        pasteCopiedShapes()
    }

    @discardableResult
    private func copySelectedShapes() -> Bool {
        // 오늘 수정 상세:
        // 복사는 현재 선택 Set의 shape들을 index 오름차순으로 보관한다.
        // 순서를 안정적으로 유지해야 여러 객체를 붙여넣었을 때 Polygon Labels row 순서와 선택 상태가 예측 가능하다.
        guard interactionMode == .edit,
              let annotation else {
            return false
        }

        let shapes = selectedShapeIndexes
            .sorted()
            .compactMap { index -> LabelMeAnnotation.Shape? in
                guard annotation.shapes.indices.contains(index) else { return nil }
                return annotation.shapes[index]
            }
        guard !shapes.isEmpty else { return false }

        Self.copiedShapes = shapes
        return true
    }

    @discardableResult
    private func pasteCopiedShapes() -> Bool {
        // 오늘 수정 상세:
        // 붙여넣기는 현재 이미지의 annotation.shapes 끝에 복사된 Shape들을 그대로 append한다.
        // 좌표 변환은 하지 않으므로 같은 해상도/비슷한 구도의 다른 이미지에서 label 정보를 재사용하는 용도다.
        // 붙여넣은 shape index들을 즉시 선택 Set으로 만들어 사용자가 바로 이동/삭제/재복사할 수 있게 한다.
        guard interactionMode == .edit,
              !Self.copiedShapes.isEmpty,
              var annotation else {
            return false
        }

        pushUndoSnapshot()
        let firstPastedIndex = annotation.shapes.count
        annotation.shapes.append(contentsOf: Self.copiedShapes)
        let pastedIndexes = Set(firstPastedIndex..<annotation.shapes.count)

        self.annotation = annotation
        selectedShapeIndexes = pastedIndexes
        selectedShapeIndex = pastedIndexes.sorted().first
        selectedVertex = nil
        hoveredShapeIndex = selectedShapeIndex
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        visibleShapeIndexes.formUnion(pastedIndexes)
        onAnnotationChanged?(annotation)
        notifySelectedShapeChanged()
        needsDisplay = true
        return true
    }

    @discardableResult
    func deleteSelectedShape() -> Bool {
        // 오늘 수정: edit 모드에서 선택된 shape만 삭제하고, 선택이 없으면 아무 작업도 하지 않는다.
        guard interactionMode == .edit,
              let selectedShapeIndex,
              var annotation = annotation,
              annotation.shapes.indices.contains(selectedShapeIndex) else {
            return false
        }

        let oldVisibleShapeIndexes = visibleShapeIndexes
        pushUndoSnapshot()
        annotation.shapes.remove(at: selectedShapeIndex)

        // 오늘 수정: 삭제된 shape와 관련된 hover/drag/selection 상태를 모두 비운다.
        self.selectedShapeIndex = nil
        selectedShapeIndexes = []
        selectedVertex = nil
        hoveredShapeIndex = nil
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        self.annotation = annotation
        // 오늘 수정: 삭제 뒤 뒤쪽 shape index가 하나씩 당겨지므로 visible index도 같이 보정한다.
        visibleShapeIndexes = Set(oldVisibleShapeIndexes.compactMap { index in
            if index == selectedShapeIndex {
                return nil
            }
            return index > selectedShapeIndex ? index - 1 : index
        })
        onAnnotationChanged?(annotation)
        notifySelectedShapeChanged()
        NSCursor.arrow.set()
        needsDisplay = true
        return true
    }

    private func showVertexContextMenu(for vertex: VertexSelection) {
        guard let menuLocation = viewLocation(for: vertex) else { return }

        // 오늘 수정: NSMenu는 선택 꼭지점의 view 좌표에서 popUp한다.
        // 사용자 요구처럼 꼭지점 위치를 메뉴의 기준점으로 삼기 위해 mouse 위치 대신 viewLocation(for:)를 사용한다.
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(
            contextMenuItem(
                title: "Delete Polygons",
                systemSymbolName: "xmark",
                action: #selector(deletePolygonFromContextMenu(_:)),
                isEnabled: selectedShapeIndex != nil
            )
        )
        menu.addItem(
            contextMenuItem(
                title: "Undo",
                systemSymbolName: "arrow.uturn.backward",
                action: #selector(undoAnnotationEditFromContextMenu(_:)),
                isEnabled: !undoSnapshots.isEmpty
            )
        )

        let undoLastPointItem = contextMenuItem(
            title: "Undo last point",
            systemSymbolName: "arrow.uturn.backward",
            action: nil,
            isEnabled: false
        )
        menu.addItem(undoLastPointItem)

        menu.addItem(
            contextMenuItem(
                title: "Remove Selected Point",
                systemSymbolName: "pencil.and.scribble",
                action: #selector(removeSelectedPointFromContextMenu(_:)),
                isEnabled: canRemoveSelectedPoint
            )
        )

        menu.popUp(positioning: nil, at: menuLocation, in: self)
    }

    private func contextMenuItem(
        title: String,
        systemSymbolName: String,
        action: Selector?,
        isEnabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: title)
        return item
    }

    private var canRemoveSelectedPoint: Bool {
        guard let selectedVertex,
              let annotation,
              annotation.shapes.indices.contains(selectedVertex.shapeIndex),
              annotation.shapes[selectedVertex.shapeIndex].points.indices.contains(selectedVertex.vertexIndex) else {
            return false
        }

        let shape = annotation.shapes[selectedVertex.shapeIndex]
        // 오늘 수정: rectangle은 LabelMe 저장 포맷상 두 점만 가진 shape라 point 삭제를 허용하지 않는다.
        // polygon도 점이 3개 이하가 되면 면을 만들 수 없으므로 4개 이상일 때만 삭제 가능하다.
        return !isRectangle(shape) && shape.points.count > 3
    }

    @discardableResult
    private func removeSelectedPoint() -> Bool {
        guard canRemoveSelectedPoint,
              let selectedVertex,
              var annotation = annotation else {
            return false
        }

        pushUndoSnapshot()
        // 오늘 수정: 선택 꼭지점 삭제 직전 상태를 undo stack에 저장한 뒤 실제 point를 제거한다.
        annotation.shapes[selectedVertex.shapeIndex].points.remove(at: selectedVertex.vertexIndex)
        self.annotation = annotation
        selectedShapeIndex = selectedVertex.shapeIndex
        selectedShapeIndexes = [selectedVertex.shapeIndex]
        self.selectedVertex = nil
        hoveredVertex = nil
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        onAnnotationChanged?(annotation)
        notifySelectedShapeChanged()
        NSCursor.arrow.set()
        needsDisplay = true
        return true
    }

    @discardableResult
    private func undoLastAnnotationEdit() -> Bool {
        guard let snapshot = undoSnapshots.popLast() else { return false }

        // 오늘 수정: undo는 annotation뿐 아니라 visible 상태와 선택 상태도 함께 되돌린다.
        // 그래야 오른쪽 Polygon Labels checkbox/selection과 preview 강조가 이전 상태와 맞는다.
        annotation = snapshot.annotation
        visibleShapeIndexes = snapshot.visibleShapeIndexes
        selectedShapeIndex = snapshot.selectedShapeIndex
        selectedShapeIndexes = snapshot.selectedShapeIndexes
        selectedVertex = isValidVertexSelection(snapshot.selectedVertex, in: snapshot.annotation)
            ? snapshot.selectedVertex
            : nil
        hoveredShapeIndex = selectedShapeIndex
        hoveredVertex = selectedVertex
        draggingVertex = nil
        draggingShapeIndex = nil
        shapeDragLastImagePoint = nil
        isPanningImage = false
        panDragLastLocationInWindow = nil
        hasPushedUndoForCurrentDrag = false
        onAnnotationChanged?(snapshot.annotation)
        notifySelectedShapeChanged()
        needsDisplay = true
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        if interactionMode == .edit, key == "z", !modifierFlags.contains(.shift) {
            return undoLastAnnotationEdit()
        }
        if interactionMode == .edit, key == "c" {
            return copySelectedShapes()
        }
        if interactionMode == .edit, key == "v" {
            return pasteCopiedShapes()
        }

        guard interactionMode == .create else {
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
            let activeVertex = draggingVertex ?? selectedVertex ?? hoveredVertex
            let isActiveShape = isEditingEnabled &&
                (
                    // 오늘 수정: toolbar 삭제 대상인 선택 shape도 hover shape처럼 강조해서 표시한다.
                    selectedShapeIndexes.contains(shapeIndex) ||
                    shapeIndex == selectedShapeIndex ||
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
        if displayedImageRect.width > 0, displayedImageRect.height > 0 {
            return displayedImageRect
        }

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

    private func closestPoint(
        to point: CGPoint,
        onSegmentFrom startPoint: CGPoint,
        to endPoint: CGPoint
    ) -> CGPoint {
        // 오늘 수정: polygon 선분 클릭 여부를 판단하기 위해 클릭 위치에서 선분까지의 최단점을 계산한다.
        // 이 계산은 화면 좌표(view point) 기준으로 수행해 zoom in/out 상태와 무관하게 hit 영역 크기를 일정하게 유지한다.
        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return startPoint }

        let rawRatio = ((point.x - startPoint.x) * deltaX + (point.y - startPoint.y) * deltaY) / lengthSquared
        let ratio = min(1, max(0, rawRatio))
        return CGPoint(
            x: startPoint.x + deltaX * ratio,
            y: startPoint.y + deltaY * ratio
        )
    }

    private func pushUndoSnapshot() {
        guard let annotation else { return }

        // 오늘 수정: value type인 LabelMeAnnotation을 그대로 보관해 편집 전 상태를 snapshot으로 만든다.
        // visibleShapeIndexes와 selection도 같이 저장해야 undo 후 오른쪽 목록과 preview가 같은 상태로 돌아간다.
        undoSnapshots.append(
            AnnotationSnapshot(
                annotation: annotation,
                visibleShapeIndexes: visibleShapeIndexes,
                selectedShapeIndex: selectedShapeIndex,
                selectedShapeIndexes: selectedShapeIndexes,
                selectedVertex: selectedVertex
            )
        )

        if undoSnapshots.count > 50 {
            // 오늘 수정: 장시간 편집 시 snapshot이 무한히 쌓이지 않도록 최근 50개만 유지한다.
            undoSnapshots.removeFirst()
        }
    }

    private func pushUndoSnapshotForCurrentDragIfNeeded() {
        guard !hasPushedUndoForCurrentDrag else { return }

        pushUndoSnapshot()
        hasPushedUndoForCurrentDrag = true
    }

    private func notifySelectedShapeChanged() {
        // 오늘 수정: preview overlay의 선택 상태가 바뀌면 ImageControlViewController가 Polygon Labels row를 맞춘다.
        // 선택 해제도 빈 Set으로 전달해 table selection을 지우게 한다.
        onSelectedShapeChanged?(selectedShapeIndexes)
    }

    private func isValidVertexSelection(
        _ selection: VertexSelection?,
        in annotation: LabelMeAnnotation?
    ) -> Bool {
        guard let selection else { return false }
        return isValidVertexSelection(selection, in: annotation)
    }

    private func isValidVertexSelection(
        _ selection: VertexSelection,
        in annotation: LabelMeAnnotation?
    ) -> Bool {
        guard let annotation,
              annotation.shapes.indices.contains(selection.shapeIndex) else {
            return false
        }

        return handleImagePoints(for: annotation.shapes[selection.shapeIndex])
            .indices
            .contains(selection.vertexIndex)
    }

    private func viewLocation(for vertex: VertexSelection) -> CGPoint? {
        // 오늘 수정: context menu를 mouse 위치가 아니라 선택 꼭지점 위치에 띄우기 위한 좌표 변환이다.
        // rectangle은 표시 handle이 실제 저장 points와 다를 수 있으므로 handleImagePoints를 통해 표시용 점을 가져온다.
        guard let annotation,
              annotation.shapes.indices.contains(vertex.shapeIndex),
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return nil
        }

        let imagePoints = handleImagePoints(for: annotation.shapes[vertex.shapeIndex])
        guard imagePoints.indices.contains(vertex.vertexIndex) else { return nil }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        return viewPoint(
            for: imagePoints[vertex.vertexIndex],
            imageRect: imageRect,
            imageSize: annotation.imageSize
        )
    }

    private func updateCursor(at location: CGPoint) {
        switch interactionMode {
        case .inactive:
            NSCursor.arrow.set()
        case .create:
            NSCursor.crosshair.set()
        case .edit:
            let newHoveredVertex = vertexSelection(at: location)
            let newHoveredSegment = newHoveredVertex == nil ? segmentSelection(at: location) : nil
            let newHoveredShapeIndex = newHoveredVertex?.shapeIndex ?? newHoveredSegment?.shapeIndex ?? shapeIndex(at: location)
            if newHoveredVertex != hoveredVertex || newHoveredShapeIndex != hoveredShapeIndex {
                hoveredVertex = newHoveredVertex
                hoveredShapeIndex = newHoveredShapeIndex
                needsDisplay = true
            }

            if newHoveredVertex != nil || newHoveredSegment != nil {
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

    private func segmentSelection(at location: CGPoint) -> SegmentSelection? {
        // 오늘 수정: edit 모드에서 polygon 선 위를 클릭하면 새 꼭지점 삽입 대상으로 선택한다.
        // 꼭지점 hit-test가 먼저 실행되므로, 이 함수는 기존 꼭지점이 아닌 선분만 대상으로 한다.
        guard interactionMode == .edit,
              let annotation = annotation,
              annotation.imageSize.width > 0,
              annotation.imageSize.height > 0 else {
            return nil
        }

        let imageRect = fittedImageRect(for: annotation.imageSize)
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }

        for shapeIndex in annotation.shapes.indices.reversed() {
            let shape = annotation.shapes[shapeIndex]
            guard visibleShapeIndexes.contains(shapeIndex),
                  !isRectangle(shape),
                  shape.points.count >= 3 else {
                // 오늘 수정: rectangle은 LabelMe rectangle 포맷을 유지해야 하므로 선분 중간 점 삽입 대상에서 제외한다.
                continue
            }

            let viewPoints = shape.points.map {
                viewPoint(
                    for: CGPoint(x: $0.x, y: $0.y),
                    imageRect: imageRect,
                    imageSize: annotation.imageSize
                )
            }
            var bestSelection: SegmentSelection?
            var bestDistance = CGFloat.greatestFiniteMagnitude

            for startIndex in viewPoints.indices {
                let endIndex = startIndex == viewPoints.count - 1 ? 0 : startIndex + 1
                // 오늘 수정: 닫힌 polygon이므로 마지막 점과 첫 점 사이의 선분도 후보에 포함한다.
                let closestViewPoint = closestPoint(
                    to: location,
                    onSegmentFrom: viewPoints[startIndex],
                    to: viewPoints[endIndex]
                )
                let hitDistance = distance(from: location, to: closestViewPoint)
                guard hitDistance <= HandleStyle.hitDiameter / 2,
                      hitDistance < bestDistance else {
                    continue
                }

                // 오늘 수정: 마지막-첫 점 선분에 삽입하는 경우 배열 끝에 append하는 것이 polygon 순서를 보존한다.
                let insertIndex = endIndex == 0 ? shape.points.count : endIndex
                bestDistance = hitDistance
                bestSelection = SegmentSelection(
                    shapeIndex: shapeIndex,
                    insertIndex: insertIndex,
                    imagePoint: clampedImagePoint(
                        for: closestViewPoint,
                        imageRect: imageRect,
                        imageSize: annotation.imageSize
                    )
                )
            }

            if let bestSelection {
                return bestSelection
            }
        }

        return nil
    }

    @discardableResult
    private func insertVertex(at segmentSelection: SegmentSelection) -> VertexSelection? {
        guard var annotation = annotation,
              annotation.shapes.indices.contains(segmentSelection.shapeIndex),
              !isRectangle(annotation.shapes[segmentSelection.shapeIndex]) else {
            return nil
        }

        // 오늘 수정: hit-test가 계산한 삽입 index를 실제 points 배열 범위 안으로 보정한다.
        let insertIndex = min(
            max(0, segmentSelection.insertIndex),
            annotation.shapes[segmentSelection.shapeIndex].points.count
        )
        pushUndoSnapshot()
        hasPushedUndoForCurrentDrag = true
        // 오늘 수정: 새 점 삽입은 클릭 직후 바로 드래그될 수 있으므로,
        // 삽입 전 상태를 undo에 저장하고 현재 drag gesture에서는 추가 snapshot을 만들지 않게 표시한다.
        annotation.shapes[segmentSelection.shapeIndex].points.insert(
            LabelMeAnnotation.Point(
                x: segmentSelection.imagePoint.x,
                y: segmentSelection.imagePoint.y
            ),
            at: insertIndex
        )

        self.annotation = annotation
        selectedShapeIndex = segmentSelection.shapeIndex
        selectedShapeIndexes = [segmentSelection.shapeIndex]
        hoveredShapeIndex = segmentSelection.shapeIndex
        onAnnotationChanged?(annotation)
        // 오늘 수정: 삽입한 점을 곧바로 선택된 vertex로 돌려주면 mouseDragged에서 그 점 위치를 계속 갱신할 수 있다.
        let selection = VertexSelection(shapeIndex: segmentSelection.shapeIndex, vertexIndex: insertIndex)
        hoveredVertex = selection
        needsDisplay = true
        return selection
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

    private func clampedImagePoint(
        for viewPoint: CGPoint,
        imageRect: CGRect,
        imageSize: NSSize
    ) -> CGPoint {
        // 오늘 수정: 선분 hit-test는 view 좌표에서 수행하지만 LabelMe JSON에는 image 좌표를 저장해야 한다.
        // zoom/scroll 후에도 정확히 저장되도록 displayed image rect 기준으로 다시 image 좌표로 변환한다.
        let rawPoint = CGPoint(
            x: (viewPoint.x - imageRect.minX) * imageSize.width / imageRect.width,
            y: (viewPoint.y - imageRect.minY) * imageSize.height / imageRect.height
        )

        // 오늘 수정: 수치 오차나 이미지 경계 근처 클릭으로 좌표가 이미지 바깥으로 나가지 않도록 clamp한다.
        return CGPoint(
            x: min(imageSize.width, max(0, rawPoint.x)),
            y: min(imageSize.height, max(0, rawPoint.y))
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
