//
//  ImageControlViewController.swift
//  ImageCat
//
//  Created by headway on 2026/06/16.
//

import Cocoa

class ImageControlViewController: NSViewController{
    private enum PolygonLabelColumn {
        static let row = NSUserInterfaceItemIdentifier("PolygonLabelRowColumn")
        static let cell = NSUserInterfaceItemIdentifier("PolygonLabelRowCell")
    }

    private enum PolygonLabelLayout {
        static let checkboxLeading: CGFloat = 8
        static let checkboxSize: CGFloat = 18
        static let colorDotSize: CGFloat = 12
        static let checkboxToLabelSpacing: CGFloat = 10
        static let labelToColorSpacing: CGFloat = 8
        static let trailingPadding: CGFloat = 8
    }

    @IBOutlet weak var controlSplitView: NSSplitView!
    @IBOutlet weak var curveControl: ImageCurveControl!
    @IBOutlet weak var resetButton: NSButton!
    
    @IBOutlet weak var polygonLabelsTableView: NSTableView!
    
    private var polygonLabelRows: [PolygonLabelRow] = []
    // 폴더 label-color scan 결과가 나중에 도착해도 현재 annotation 목록을 다시 색칠할 수 있게 보관한다.
    private var currentAnnotation: LabelMeAnnotation?
    // 폴더 전체에서 계산한 label-color set이다. 오른쪽 목록과 overlay가 같은 색 기준을 공유한다.
    private var folderLabelColorPairs: Set<LabelColorPair> = []

    private var didSetInitialControlSplitPositions = false
    
    private var imagePreviewViewController: ImagePreviewViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImagePreviewViewController }
            .first
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        controlSplitView.isVertical = false
        controlSplitView.arrangesAllSubviews = true

        // 드래그 중에는 낮은 해상도의 빠른 프리뷰로 커브 변경을 즉시 보여준다.
        curveControl.onCurveChanged = { [weak self] curveControl in
            self?.imagePreviewViewController?.applyCurve(using: curveControl, isInteractive: true)
        }
        // 마우스를 놓으면 더 높은 해상도의 최종 프리뷰를 다시 렌더링한다.
        curveControl.onCurveEditingEnded = { [weak self] curveControl in
            self?.imagePreviewViewController?.applyCurve(using: curveControl)
        }
        
        polygonLabelsTableView.dataSource = self
        polygonLabelsTableView.delegate = self
        configurePolygonLabelsTableView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        setInitialControlSplitViewHeightsIfNeeded()
        updatePolygonLabelColumnWidth()
    }

    private func setInitialControlSplitViewHeightsIfNeeded() {
        guard !didSetInitialControlSplitPositions,
              controlSplitView.subviews.count == 3,
              controlSplitView.bounds.height > 0 else {
            return
        }

        didSetInitialControlSplitPositions = true

        let thirdHeight = controlSplitView.bounds.height / 3
        controlSplitView.setPosition(thirdHeight, ofDividerAt: 0)
        controlSplitView.setPosition(thirdHeight * 2, ofDividerAt: 1)
    }

    // 버튼을 누를 때 실행될 함수
    @IBAction func resetButtonClicked(_ sender: NSButton) {
        print("Curve 초기화 버튼이 클릭되었습니다.")
        
        // 여기에 초기화 관련 로직을 작성하세요.
        // 예: 그래프 데이터를 리셋하거나 화면을 다시 그리는 코드
        curveControl.resetPoints()
        
    }
    
    func updatePolygonLabels(from annotation: LabelMeAnnotation?) {
        currentAnnotation = annotation
        rebuildPolygonLabelRows(preservingVisibility: false)
    }

    func setFolderLabelColorPairs(_ pairs: Set<LabelColorPair>) {
        folderLabelColorPairs = pairs
        // 색상 scan 결과만 바뀐 경우에는 사용자가 꺼둔 checkbox 상태를 유지한다.
        rebuildPolygonLabelRows(preservingVisibility: true)
    }

    private func rebuildPolygonLabelRows(preservingVisibility: Bool) {
        let previousVisibility = Dictionary(
            uniqueKeysWithValues: polygonLabelRows.map { ($0.shapeIndex, $0.isVisible) }
        )

        guard let annotation = currentAnnotation else {
            polygonLabelRows = []
            applyPolygonVisibilityToPreview()
            reloadPolygonLabelsTableIfLoaded()
            return
        }

        let labels = annotation.shapes.map { $0.label }
        let colors = LabelColorProvider.colors(for: labels, preferredPairs: folderLabelColorPairs)

        polygonLabelRows = annotation.shapes.enumerated().map { index, shape in
            PolygonLabelRow(
                shapeIndex: index,
                label: shape.label,
                color: colors[shape.label] ?? .systemBlue,
                isVisible: preservingVisibility ? previousVisibility[index] ?? true : true
            )
        }

        applyPolygonVisibilityToPreview()
        reloadPolygonLabelsTableIfLoaded()
    }

    private func reloadPolygonLabelsTableIfLoaded() {
        guard isViewLoaded, let polygonLabelsTableView = polygonLabelsTableView else { return }
        updatePolygonLabelColumnWidth()
        polygonLabelsTableView.reloadData()
    }

    private func configurePolygonLabelsTableView() {
        polygonLabelsTableView.columnAutoresizingStyle = .noColumnAutoresizing
        polygonLabelsTableView.intercellSpacing = .zero
        polygonLabelsTableView.headerView = nil
        polygonLabelsTableView.allowsColumnResizing = false
        polygonLabelsTableView.tableColumns.forEach { polygonLabelsTableView.removeTableColumn($0) }

        let column = NSTableColumn(identifier: PolygonLabelColumn.row)
        column.title = ""
        column.minWidth = 0
        column.maxWidth = CGFloat.greatestFiniteMagnitude
        column.resizingMask = .autoresizingMask
        polygonLabelsTableView.addTableColumn(column)

        updatePolygonLabelColumnWidth()
    }

    private func updatePolygonLabelColumnWidth() {
        guard let column = polygonLabelsTableView.tableColumn(withIdentifier: PolygonLabelColumn.row) else { return }
        let width = max(polygonLabelsTableView.bounds.width, polygonLabelContentWidth())
        column.width = width
        column.minWidth = width
        column.maxWidth = CGFloat.greatestFiniteMagnitude
    }

    private func polygonLabelContentWidth() -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        let widestLabelWidth = polygonLabelRows
            .map { ceil(($0.label as NSString).size(withAttributes: attributes).width) }
            .max() ?? 0

        return PolygonLabelLayout.checkboxLeading
            + PolygonLabelLayout.checkboxSize
            + PolygonLabelLayout.checkboxToLabelSpacing
            + widestLabelWidth
            + PolygonLabelLayout.labelToColorSpacing
            + PolygonLabelLayout.colorDotSize
            + PolygonLabelLayout.trailingPadding
    }

    private func applyPolygonVisibilityToPreview() {
        let visibleIndexes = Set(
            polygonLabelRows
                .filter { $0.isVisible }
                .map { $0.shapeIndex }
        )
        imagePreviewViewController?.setVisibleAnnotationShapeIndexes(visibleIndexes)
    }

    @objc private func polygonLabelCheckboxChanged(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < polygonLabelRows.count else { return }

        polygonLabelRows[row].isVisible = sender.state == .on
        applyPolygonVisibilityToPreview()
    }
}
extension ImageControlViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return polygonLabelRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < polygonLabelRows.count else { return nil }
        let item = polygonLabelRows[row]

        let cell = tableView.makeView(
            withIdentifier: PolygonLabelColumn.cell,
            owner: self
        ) as? PolygonLabelRowCellView ?? PolygonLabelRowCellView()
        cell.identifier = PolygonLabelColumn.cell
        cell.configure(
            label: item.label,
            color: item.color,
            isVisible: item.isVisible,
            row: row,
            target: self,
            action: #selector(polygonLabelCheckboxChanged(_:))
        )
        return cell
    }
}

private final class PolygonLabelRowCellView: NSTableCellView {
    private enum Layout {
        static let checkboxLeading: CGFloat = 8
        static let checkboxSize: CGFloat = 18
        static let checkboxToLabelSpacing: CGFloat = 10
        static let labelToColorSpacing: CGFloat = 8
        static let colorDotSize: CGFloat = 12
    }

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let labelField = NSTextField(labelWithString: "")
    private let dotView = ColorDotView(color: .systemBlue)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configure(
        label: String,
        color: NSColor,
        isVisible: Bool,
        row: Int,
        target: AnyObject?,
        action: Selector
    ) {
        checkbox.state = isVisible ? .on : .off
        checkbox.tag = row
        checkbox.target = target
        checkbox.action = action

        labelField.stringValue = label
        dotView.color = color

        needsLayout = true
    }

    override func layout() {
        super.layout()

        checkbox.frame = NSRect(
            x: Layout.checkboxLeading,
            y: centeredY(for: Layout.checkboxSize),
            width: Layout.checkboxSize,
            height: Layout.checkboxSize
        )

        let labelSize = labelField.intrinsicContentSize
        let labelX = checkbox.frame.maxX + Layout.checkboxToLabelSpacing
        labelField.frame = NSRect(
            x: labelX,
            y: centeredY(for: labelSize.height),
            width: ceil(labelSize.width),
            height: labelSize.height
        )

        dotView.frame = NSRect(
            x: labelField.frame.maxX + Layout.labelToColorSpacing,
            y: centeredY(for: Layout.colorDotSize),
            width: Layout.colorDotSize,
            height: Layout.colorDotSize
        )
    }

    private func configureView() {
        checkbox.title = ""
        checkbox.allowsMixedState = false
        checkbox.translatesAutoresizingMaskIntoConstraints = true

        labelField.textColor = .labelColor
        labelField.font = .systemFont(ofSize: NSFont.systemFontSize)
        labelField.lineBreakMode = .byClipping
        labelField.translatesAutoresizingMaskIntoConstraints = true

        dotView.translatesAutoresizingMaskIntoConstraints = true

        addSubview(checkbox)
        addSubview(labelField)
        addSubview(dotView)
    }

    private func centeredY(for height: CGFloat) -> CGFloat {
        return max(0, (bounds.height - height) / 2)
    }
}
