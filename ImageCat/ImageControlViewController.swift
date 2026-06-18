//
//  ImageControlViewController.swift
//  ImageCat
//
//  Created by headway on 2026/06/16.
//

import Cocoa

class ImageControlViewController: NSViewController {

    @IBOutlet weak var curveControl: ImageCurveControl!
    @IBOutlet weak var resetButton: NSButton!
    
    private var imagePreviewViewController: ImagePreviewViewController? {
        return (parent as? NSSplitViewController)?.splitViewItems
            .compactMap { $0.viewController as? ImagePreviewViewController }
            .first
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        curveControl.onCurveChanged = { [weak self] curveControl in
                    self?.imagePreviewViewController?.applyCurve(using: curveControl)
                }
    }
    // 버튼을 누를 때 실행될 함수
    @IBAction func resetButtonClicked(_ sender: NSButton) {
        print("Curve 초기화 버튼이 클릭되었습니다.")
        
        // 여기에 초기화 관련 로직을 작성하세요.
        // 예: 그래프 데이터를 리셋하거나 화면을 다시 그리는 코드
        curveControl.resetPoints()
        
    }
}
