//
//  ImageControlViewController.swift
//  ImageCat
//
//  Created by headway on 2026/06/16.
//

import Cocoa

class ImageControlViewController: NSViewController {

    @IBOutlet weak var controlSplitView: NSSplitView!
    @IBOutlet weak var curveControl: ImageCurveControl!
    @IBOutlet weak var resetButton: NSButton!

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
        ownSplitViewItem?.minimumThickness = width
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
}
