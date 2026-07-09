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
    
    // 오늘 수정: Label List table의 Storyboard column identifier와 코드 분기를 맞추기 위한 이름이다.
    private enum LabelListColumn {
        static let label = NSUserInterfaceItemIdentifier("LabelListLabelColumn")
        static let color = NSUserInterfaceItemIdentifier("LabelListColorColumn")
    }

    // 오늘 수정: makeView는 column identifier가 아니라 prototype cell identifier로 Storyboard cell을 찾는다.
    private enum LabelListCell {
        static let label = NSUserInterfaceItemIdentifier("LabelCell")
        static let color = NSUserInterfaceItemIdentifier("ColorCell")
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
    
    // 오늘 수정: 폴더 전체 label-color 목록을 보여주는 Label List table outlet이다.
    @IBOutlet weak var labelListTableView: NSTableView!
    
    private var polygonLabelRows: [PolygonLabelRow] = []
    // 폴더 label-color scan 결과가 나중에 도착해도 현재 annotation 목록을 다시 색칠할 수 있게 보관한다.
    private var currentAnnotation: LabelMeAnnotation?
    // 폴더 전체에서 계산한 label-color set이다. 오른쪽 목록과 overlay가 같은 색 기준을 공유한다.
    private var folderLabelColorPairs: Set<LabelColorPair> = []
    // 오늘 수정: Set은 row 순서가 없으므로 TableView가 읽을 정렬된 배열을 따로 둔다.
    private var labelColorRows: [LabelColorPair] = []
    // 오늘 수정: preview에서 객체 선택 -> Polygon Labels row 선택으로 동기화할 때
    // NSTableView selectionDidChange가 다시 preview 선택을 호출하는 순환을 막기 위한 플래그다.
    private var isSyncingPolygonLabelSelection = false

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
        // 오늘 수정: Label List table도 같은 dataSource/delegate에서 row 수와 cell view를 공급받는다.
        labelListTableView.dataSource = self
        labelListTableView.delegate = self
        configurePolygonLabelsTableView()
        labelListTableView.reloadData()
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

    func resetCurveForImageSelection() {
        guard isViewLoaded else { return }

        // 이미지가 바뀔 때 preview는 이미 원본 이미지를 다시 넣으므로 curve UI/LUT만 조용히 원점으로 되돌린다.
        // reset 버튼처럼 change handler를 호출하면 같은 원본 이미지에 대해 불필요한 렌더 요청이 한 번 더 생기므로
        // 이미지 선택 경로에서는 UI 상태와 LUT만 초기화한다.
        curveControl.resetPoints(notifiesChangeHandlers: false)
    }
    
    func updatePolygonLabels(from annotation: LabelMeAnnotation?) {
        currentAnnotation = annotation
        rebuildPolygonLabelRows(preservingVisibility: false)
    }

    func selectPolygonLabelRows(forShapeIndexes shapeIndexes: Set<Int>) {
        guard isViewLoaded, let polygonLabelsTableView = polygonLabelsTableView else { return }

        // 오늘 수정: 이 함수는 preview overlay에서 선택된 shape를 table selection에 반영하는 경로다.
        // 사용자가 table row를 직접 클릭한 경우와 구분하기 위해 동기화 중 플래그를 켠다.
        // 오늘 수정 상세:
        // preview에서 Cmd-click으로 여러 polygon을 선택하면 shape index Set이 전달된다.
        // table row 번호와 shape index는 항상 같다고 가정하지 않고 polygonLabelRows에서 매핑한다.
        // selectRowIndexes(_:byExtendingSelection: false)는 기존 table selection을 이 Set에 맞춰 완전히 교체한다.
        isSyncingPolygonLabelSelection = true
        defer { isSyncingPolygonLabelSelection = false }

        var rows = IndexSet()
        polygonLabelRows.enumerated().forEach { row, item in
            if shapeIndexes.contains(item.shapeIndex) {
                rows.insert(row)
            }
        }
        guard !rows.isEmpty else {
            // 오늘 수정: preview 쪽 선택이 해제되었거나 row가 없는 shape라면 table selection도 해제한다.
            polygonLabelsTableView.deselectAll(nil)
            return
        }

        // 오늘 수정: preview의 다중 shape 선택을 Polygon Labels table의 다중 row 선택으로 반영한다.
        polygonLabelsTableView.selectRowIndexes(rows, byExtendingSelection: false)
        if let firstRow = rows.first {
            polygonLabelsTableView.scrollRowToVisible(firstRow)
        }
    }

    func setFolderLabelColorPairs(_ pairs: Set<LabelColorPair>) {
        folderLabelColorPairs = pairs
        // 오늘 수정: 폴더 scan 결과가 들어오면 Label List table의 backing rows를 먼저 갱신한다.
        reloadLabelListView()
        // 색상 scan 결과만 바뀐 경우에는 사용자가 꺼둔 checkbox 상태를 유지한다.
        rebuildPolygonLabelRows(preservingVisibility: true)
    }
    
    private func reloadLabelListView() {
        // 오늘 수정: 데이터를 sort해서 list로 만들고, TableView가 numberOfRows/viewFor를 다시 묻게 한다.
        labelColorRows = folderLabelColorPairs.sorted { $0.label < $1.label }
        guard isViewLoaded, let labelListTableView = labelListTableView else { return }
        labelListTableView.reloadData()
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
        // 오늘 수정 상세:
        // storyboard에서 Multiple Selection을 켜도 코드가 단일 선택으로 덮으면 런타임에서 한 줄만 남는다.
        // 그래서 코드에서도 명시적으로 다중 선택을 켜고, selectionDidChange에서 selectedRowIndexes 전체를 읽는다.
        polygonLabelsTableView.allowsMultipleSelection = true
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
        // 오늘 수정: 한 컨트롤러가 두 table을 담당하므로 요청한 table별 row 개수를 나눠 반환한다.
        if tableView == labelListTableView {
            return labelColorRows.count
        }

        if tableView == polygonLabelsTableView {
            return polygonLabelRows.count
        }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == labelListTableView {
            guard row < labelColorRows.count,
                      let tableColumn = tableColumn else { return nil }
            
            let item = labelColorRows[row]

            if tableColumn.identifier == LabelListColumn.label {
                // 오늘 수정: Label List의 label column은 Storyboard의 기본 text cell을 재사용한다.
                let cell = tableView.makeView(
                    withIdentifier: LabelListCell.label,
                    owner: self
                ) as? LabelListRowCellView

                cell?.textField?.stringValue = item.label
                cell?.colorDotView.color = item.color
                return cell
            }

            
            return nil
        }
        
        if tableView == polygonLabelsTableView {
            guard row < polygonLabelRows.count else { return nil }
            let item = polygonLabelRows[row]

            let cell = tableView.makeView(
                // 오늘 수정: Polygon Labels table은 Label List cell이 아니라 기존 custom row cell identifier를 써야 한다.
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
        
        return nil
        
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView == polygonLabelsTableView,
              !isSyncingPolygonLabelSelection else {
            return
        }

        // 오늘 수정: 사용자가 Polygon Labels row를 직접 선택한 경우에는 모든 선택 row의 shape를 preview에서도 선택한다.
        // selectedShapeIndex는 기존 삭제/꼭지점 편집 경로를 위한 대표 선택으로만 유지한다.
        // 오늘 수정 상세:
        // NSTableView의 selectedRow는 단일 row만 알려주므로 다중 선택에는 부적합하다.
        // selectedRowIndexes 전체를 shapeIndex Set으로 바꿔 overlay에 전달해야 preview의 여러 polygon이 함께 강조된다.
        // notifiesSelectionChange=false는 table -> preview 동기화가 다시 preview -> table 동기화를 호출하지 않게 하는 안전장치다.
        let selectedShapeIndexes = Set<Int>(polygonLabelsTableView.selectedRowIndexes.compactMap { row -> Int? in
            guard row >= 0, row < polygonLabelRows.count else { return nil }
            return polygonLabelRows[row].shapeIndex
        })
        guard !selectedShapeIndexes.isEmpty else {
            // 오늘 수정: table selection이 없어지면 preview의 shape 선택도 같이 해제한다.
            imagePreviewViewController?.selectAnnotationShapes(at: [], notifiesSelectionChange: false)
            return
        }

        imagePreviewViewController?.setPolygonInteractionMode(.edit)
        view.window?.toolbar?.validateVisibleItems()
        imagePreviewViewController?.selectAnnotationShapes(
            at: selectedShapeIndexes,
            notifiesSelectionChange: false
        )
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

final class LabelListRowCellView: NSTableCellView {

    @IBOutlet weak var colorDotView: ColorDotView!
    
    func configure(label: String, color: NSColor) {
        textField?.stringValue = label
        colorDotView.color = color
    }
}
