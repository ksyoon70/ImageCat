//
//  ImageControlViewController.swift
//  ImageCat
//
//  Created by headway on 2026/06/16.
//

import Cocoa

class ImageControlViewController: NSViewController{

    @IBOutlet weak var controlSplitView: NSSplitView!
    @IBOutlet weak var curveControl: ImageCurveControl!
    @IBOutlet weak var resetButton: NSButton!
    
    @IBOutlet weak var polygonLabelsTableView: NSTableView!
    
    private var polygonLabelRows: [PolygonLabelRow] = []

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
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        setInitialControlSplitViewHeightsIfNeeded()
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        // Split View item과 curveControl frame이 모두 준비된 뒤 control pane 폭을 고정한다.
        configureFixedSplitViewItemWidth()
    }

    private var ownSplitViewItem: NSSplitViewItem? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .first { $0.viewController === self }
    }

    private func configureFixedSplitViewItemWidth() {
        view.layoutSubtreeIfNeeded()

        let width = ceil(curveControl.frame.width)
        guard width > 0 else { return }

        ownSplitViewItem?.canCollapse = false
        // ImageCurveControl의 설계 폭을 pane 폭으로 삼기 위해 최소/최대 폭을 같은 값으로 묶는다.
        ownSplitViewItem?.minimumThickness = width*2/3
        ownSplitViewItem?.maximumThickness = width
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
        guard let annotation else {
            polygonLabelRows = []
            applyPolygonVisibilityToPreview()
            reloadPolygonLabelsTableIfLoaded()
            return
        }

        let labels = annotation.shapes.map { $0.label }
        let colors = LabelColorProvider.colors(for: labels)

        polygonLabelRows = annotation.shapes.enumerated().map { index, shape in
            PolygonLabelRow(
                shapeIndex: index,
                label: shape.label,
                color: colors[shape.label] ?? .systemBlue,
                isVisible: true
            )
        }

        applyPolygonVisibilityToPreview()
        reloadPolygonLabelsTableIfLoaded()
    }

    private func reloadPolygonLabelsTableIfLoaded() {
        guard isViewLoaded, let polygonLabelsTableView = polygonLabelsTableView else { return }
        polygonLabelsTableView.reloadData()
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

        if tableColumn?.identifier.rawValue == "CheckColumn" {
            let cell = reusableCell(
                for: tableView,
                identifier: NSUserInterfaceItemIdentifier("CheckCell")
            )
            let checkbox = cell.subviews.compactMap { $0 as? NSButton }.first ?? makeCheckbox()
            checkbox.title = ""
            checkbox.state = item.isVisible ? .on : .off
            checkbox.tag = row
            checkbox.target = self
            checkbox.action = #selector(polygonLabelCheckboxChanged(_:))
            if checkbox.superview == nil {
                checkbox.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(checkbox)
                NSLayoutConstraint.activate([
                    checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            return cell
        }

        if tableColumn?.identifier.rawValue == "LabelColumn" {
            let cell = reusableCell(
                for: tableView,
                identifier: NSUserInterfaceItemIdentifier("LabelCell")
            )
            let textField = cell.textField ?? makeLabelTextField()
            textField.stringValue = item.label
            if textField.superview == nil {
                textField.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            return cell
        }

        if tableColumn?.identifier.rawValue == "ColorColumn" {
            let cell = reusableCell(
                for: tableView,
                identifier: NSUserInterfaceItemIdentifier("ColorCell")
            )
            cell.subviews.forEach { $0.removeFromSuperview() }

            let dot = ColorDotView(color: item.color)
            dot.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(dot)

            NSLayoutConstraint.activate([
                dot.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 12),
                dot.heightAnchor.constraint(equalToConstant: 12)
            ])

            return cell
        }

        return nil
    }

    private func reusableCell(for tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
    }

    private func makeCheckbox() -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.allowsMixedState = false
        return checkbox
    }

    private func makeLabelTextField() -> NSTextField {
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }
}
