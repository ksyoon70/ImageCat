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

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        updateImage()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        
        ownSplitViewItem?.minimumThickness = 220
        ownSplitViewItem?.maximumThickness = CGFloat.greatestFiniteMagnitude

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

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func updateImage() {
        guard isViewLoaded else { return }
        guard let imageURL = imageURL, let image = NSImage(contentsOf: imageURL) else {
            // 이미지가 없어질 때 진행 중이거나 대기 중인 렌더 결과를 모두 무효화한다.
            renderGeneration += 1
            originalImage = nil
            pendingRenderRequest = nil
            imageView.image = nil
            emptyLabel.isHidden = false
            return
        }

        // 새 이미지를 선택하면 이전 이미지 기준의 렌더링 결과가 화면에 반영되지 않게 한다.
        renderGeneration += 1
        originalImage = image
        pendingRenderRequest = nil
        imageView.image = image
        emptyLabel.isHidden = true
    }

    private var ownSplitViewItem: NSSplitViewItem? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .first { $0.viewController === self }
    }

    // 프리뷰 영역과 인접 영역의 폭을 마우스로 조절할 수 있도록 Split View 제한값을 명시한다.
    private func configureResizableSplitViewItems() {
        guard let splitViewController = parent as? NSSplitViewController else { return }

        for splitViewItem in splitViewController.splitViewItems {
            splitViewItem.canCollapse = false
            splitViewItem.maximumThickness = CGFloat.greatestFiniteMagnitude
        }

        ownSplitViewItem?.minimumThickness = 160
        ownSplitViewItem?.maximumThickness = CGFloat.greatestFiniteMagnitude
        ownSplitViewItem?.holdingPriority = .defaultLow

        splitViewController.splitViewItems
            .first { $0.viewController is ImageControlViewController }?
            .minimumThickness = 180
        splitViewController.splitViewItems
            .first { $0.viewController is ImageControlViewController }?
            .maximumThickness = CGFloat.greatestFiniteMagnitude
        splitViewController.splitViewItems
            .first { $0.viewController is ImageControlViewController }?
            .holdingPriority = .defaultLow
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
}

private extension NSImage {
    // 커브 렌더링에 사용할 CGImage를 안정적으로 꺼내기 위한 헬퍼다.
    func cgImageForPreviewRendering() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
