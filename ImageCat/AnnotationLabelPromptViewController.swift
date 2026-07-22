//
//  AnnotationLabelPromptViewController.swift
//  ImageCat
//
//  Created by headway on 2026/07/21.
//

import Cocoa

class AnnotationLabelPromptViewController: NSViewController {

    // Storyboard의 label 입력 필드와 기존 label 목록 테이블을 연결한다.
    @IBOutlet private weak var labelTextField: NSTextField!
    @IBOutlet private weak var groupIDTextField : NSTextField!

    @IBOutlet weak var labelsTableView: NSTableView!
    // 다이얼로그를 열 때 전달받은 label 목록의 표시용 사본이다.
    private var labels: [String] = []

    // Window Controller가 등록한다. 값이면 OK, nil이면 Cancel을 의미한다.
    var onComplete: ((String?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.
        labelsTableView.dataSource = self
        labelsTableView.delegate = self
        labelsTableView.headerView = nil
        labelsTableView.reloadData()
    }
    
    @IBAction func ok(_ sender: Any) {
        let label = labelTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // 빈 문자열은 새 도형 생성 취소와 같은 결과로 전달한다.
        onComplete?(label.isEmpty ? nil : label)
    }
    @IBAction func cancel(_ sender: Any) {
        onComplete?(nil)
    }

    func configure( existingLabels: [String])
    {
        // 다이얼로그를 열 때마다 현재 이미지의 목록으로 갱신한다.
        // 중복을 제외하고, 입력된 순서는 유지한다.
        var seen = Set<String>()
        labels = existingLabels.filter { seen.insert($0).inserted }

        if isViewLoaded {
            labelsTableView.reloadData()
        }

    }
}

extension AnnotationLabelPromptViewController:
    NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        labels.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("LabelCell")

        guard let cell = tableView.makeView(
            withIdentifier: id,
            owner: self
        ) as? NSTableCellView else {
            return nil
        }

        cell.textField?.stringValue = labels[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = labelsTableView.selectedRow

        guard labels.indices.contains(row) else { return }

        // 목록에서 선택한 label을 위 입력칸에 복사해 바로 OK할 수 있게 한다.
        labelTextField.stringValue = labels[row]
    }
}
