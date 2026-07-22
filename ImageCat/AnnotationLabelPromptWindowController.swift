//
//  AnnotationLabelPromptWindowController.swift
//  ImageCat
//
//  Created by headway on 2026/07/21.
//

import Cocoa

/// Storyboard로 만든 label 입력 창을 기존 NSAlert처럼 동기식 모달 창으로 표시한다.
final class AnnotationLabelPromptWindowController: NSWindowController, NSWindowDelegate {
    private var result: String?

    /// - Parameters:
    ///   - screenPoint: 다이얼로그를 표시할 화면 좌표. `NSEvent.mouseLocation`을 전달한다.
    ///   - parent: 다이얼로그를 소유할 문서 창이다.
    ///   - existingLabels: 테이블에 표시할 기존 label 목록이다.
    func runModal(
        near screenPoint: NSPoint,
        parent: NSWindow?,
        existingLabels: [String]
    ) -> String? {
        guard let dialogWindow = window,
              let viewController = contentViewController as? AnnotationLabelPromptViewController else {
            return nil
        }

        result = nil
        viewController.configure(existingLabels: existingLabels)
        viewController.onComplete = { [weak self] label in
            self?.result = label
            NSApp.stopModal(withCode: label == nil ? .cancel : .OK)
        }

        position(dialogWindow, near: screenPoint)
        parent?.addChildWindow(dialogWindow, ordered: .above)
        dialogWindow.makeKeyAndOrderFront(nil)

        let response = NSApp.runModal(for: dialogWindow)

        dialogWindow.orderOut(nil)
        parent?.removeChildWindow(dialogWindow)
        return response == .OK ? result : nil
    }

    /// 제목 막대의 닫기 버튼도 Cancel과 같은 결과가 되게 한다.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        result = nil
        NSApp.stopModal(withCode: .cancel)
        return false
    }

    private func position(_ dialogWindow: NSWindow, near screenPoint: NSPoint) {
        var origin = NSPoint(
            x: screenPoint.x - dialogWindow.frame.width / 2,
            y: screenPoint.y - dialogWindow.frame.height - 8
        )

        // 다이얼로그가 화면 밖으로 나가지 않도록 현재 화면의 visible frame 안으로 제한한다.
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(screenPoint) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - dialogWindow.frame.width)
            origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - dialogWindow.frame.height)
        }

        dialogWindow.setFrameOrigin(origin)
    }
}
