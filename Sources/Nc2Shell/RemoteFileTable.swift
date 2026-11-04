import SwiftUI
import AppKit
import Nc2ShellCore

struct RemoteFileTable: NSViewRepresentable {
    let model: RemoteFilesModel
    let displayedFiles: [RemoteFile]
    @Binding var selection: Set<String>
    @Binding var isDropTargeted: Bool
    let download: ([RemoteFile]) -> Void
    let createDirectory: () -> Void
    let rename: (RemoteFile) -> Void
    let delete: ([RemoteFile]) -> Void
    let properties: (RemoteFile) -> Void
    let copyPaths: ([RemoteFile]) -> Void
    let relocate: ([RemoteFile], Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        let name = NSTableColumn(identifier: .init("name")); name.minWidth = 100; name.width = 230
        let size = NSTableColumn(identifier: .init("size")); size.width = 88; size.minWidth = 88; size.maxWidth = 88
        table.addTableColumn(name); table.addTableColumn(size)
        table.headerView = nil; table.style = .fullWidth; table.rowHeight = 41
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = NSColor(WorkspaceAppearance.panel)
        table.gridStyleMask = []
        table.gridColor = NSColor(WorkspaceAppearance.line)
        table.appearance = NSAppearance(named: .darkAqua)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openClicked)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        table.onDropExit = { context.coordinator.parent.isDropTargeted = false }
        let menu = NSMenu(); menu.delegate = context.coordinator; menu.autoenablesItems = false
        table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        if coordinator.files != displayedFiles {
            coordinator.files = displayedFiles
            table.reloadData()
        }
        let indexes = IndexSet(coordinator.files.indices.filter { selection.contains(coordinator.files[$0].name) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: RemoteFileTable
        var files: [RemoteFile] = []
        weak var table: NSTableView?
        var isUpdating = false
        private var dragWriters: [Int: RemoteDownloadPromise] = [:]
        init(_ parent: RemoteFileTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { files.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WorkspaceFileRow() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard files.indices.contains(row), let column = tableColumn else { return nil }
            let file = files[row]
            if column.identifier.rawValue == "size" {
                let cell: NSTableCellView
                if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView { cell = reused }
                else {
                    cell = NSTableCellView(); cell.identifier = column.identifier
                    let label = NSTextField(labelWithString: "")
                    label.font = .systemFont(ofSize: 14)
                    label.textColor = NSColor(srgbRed: 164 / 255, green: 170 / 255, blue: 180 / 255, alpha: 1)
                    label.alignment = .right
                    label.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(label); cell.textField = label
                    NSLayoutConstraint.activate([
                        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
                        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
                cell.textField?.stringValue = file.kind == .file ? (file.hasSize ? ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file) : "未知") : "—"
                return cell
            }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView { cell = reused }
            else {
                cell = NSTableCellView(); cell.identifier = column.identifier
                let icon = NSImageView(), text = NSTextField(labelWithString: "")
                text.font = .systemFont(ofSize: 15)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(icon); cell.addSubview(text); cell.imageView = icon; cell.textField = text
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let symbol: String
            let isArchive = file.kind == .file && ["zip", "tar", "gz", "bz2", "xz", "7z", "rar"].contains((file.name as NSString).pathExtension.lowercased())
            switch file.kind { case .directory: symbol = "folder"; case .file: symbol = isArchive ? "doc.zipper" : "doc.text"; case .symbolicLink: symbol = "link"; case .other: symbol = "questionmark.square" }
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = file.kind == .directory || isArchive ? WorkspaceAppearance.orange : NSColor(srgbRed: 234 / 255, green: 232 / 255, blue: 228 / 255, alpha: 1)
            cell.textField?.stringValue = file.name; cell.toolTip = file.name
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0].name : nil })
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard files.indices.contains(row) else { return nil }
            let promise = parent.model.promiseProvider(for: files[row]) as? RemoteDownloadPromise
            dragWriters[row] = promise
            return promise
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            // 以 AppKit 实际起拖的行归组，避免预先询问 writer 时误把不同拖动合成一批。
            RemoteDownloadPromise.group(rowIndexes.compactMap { dragWriters[$0] })
            dragWriters.removeAll()
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragWriters.removeAll()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            let accepts = parent.model.canEnqueue && !localURLs(info).isEmpty
            parent.isDropTargeted = accepts
            // 文件夹行也以整个面板的当前目录为目标，与原有拖入行为一致。
            tableView.setDropRow(-1, dropOperation: .on)
            return accepts ? .copy : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            parent.isDropTargeted = false
            return parent.model.uploadDroppedItems(localURLs(info).map { NSItemProvider(object: $0 as NSURL) })
        }

        private func localURLs(_ info: NSDraggingInfo) -> [URL] {
            (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        @objc func openClicked() {
            guard let table, files.indices.contains(table.clickedRow) else { return }
            let file = files[table.clickedRow]
            if file.kind == .directory { parent.model.browse(RemoteFile.join(parent.model.path, file.name)) }
        }

        @objc private func downloadClicked() {
            let selected = selectedFiles
            guard parent.model.canDownload(selected) else { return }
            parent.download(selected)
        }

        @objc private func createDirectoryClicked() { if parent.model.canManageFiles { parent.createDirectory() } }

        @objc private func renameClicked() {
            let selected = selectedFiles
            guard selected.count == 1, parent.model.canManage(selected), let file = selected.first else { return }
            parent.rename(file)
        }

        @objc private func deleteClicked() {
            let selected = selectedFiles
            guard parent.model.canManage(selected) else { return }
            parent.delete(selected)
        }

        @objc private func propertiesClicked() {
            guard selectedFiles.count == 1, let file = selectedFiles.first else { return }
            parent.properties(file)
        }

        @objc private func copyPathsClicked() { parent.copyPaths(selectedFiles) }

        @objc private func moveClicked() { if parent.model.canManage(selectedFiles) { parent.relocate(selectedFiles, false) } }
        @objc private func copyClicked() { if parent.model.canManage(selectedFiles) { parent.relocate(selectedFiles, true) } }

        private var selectedFiles: [RemoteFile] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let create = menu.addItem(withTitle: "新建文件夹…", action: #selector(createDirectoryClicked), keyEquivalent: "")
            create.target = self; create.isEnabled = parent.model.canManageFiles
            guard let table, files.indices.contains(table.clickedRow) else { return }
            if !table.selectedRowIndexes.contains(table.clickedRow) {
                table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
            }
            let selected = selectedFiles
            let file = files[table.clickedRow]
            menu.addItem(.separator())
            if selected.count == 1 && file.kind == .directory {
                let item = menu.addItem(withTitle: "打开文件夹", action: #selector(openClicked), keyEquivalent: ""); item.target = self
            }
            if selected.count > 1 || file.kind == .file || file.kind == .directory {
                let title = selected.count > 1 ? "下载 \(selected.count) 项…" : "下载…"
                let item = menu.addItem(withTitle: title, action: #selector(downloadClicked), keyEquivalent: "")
                item.target = self; item.isEnabled = parent.model.canDownload(selected)
            }
            menu.addItem(.separator())
            let paths = menu.addItem(withTitle: selected.count > 1 ? "复制所选路径" : "复制路径", action: #selector(copyPathsClicked), keyEquivalent: "")
            paths.target = self; paths.isEnabled = !selected.isEmpty
            let properties = menu.addItem(withTitle: "属性…", action: #selector(propertiesClicked), keyEquivalent: "")
            properties.target = self; properties.isEnabled = selected.count == 1
            menu.addItem(.separator())
            let copy = menu.addItem(withTitle: "复制到…", action: #selector(copyClicked), keyEquivalent: "")
            copy.target = self; copy.isEnabled = parent.model.canManage(selected)
            let move = menu.addItem(withTitle: "移动到…", action: #selector(moveClicked), keyEquivalent: "")
            move.target = self; move.isEnabled = parent.model.canManage(selected)
            let rename = menu.addItem(withTitle: "重命名…", action: #selector(renameClicked), keyEquivalent: "")
            rename.target = self; rename.isEnabled = selected.count == 1 && parent.model.canManage(selected)
            let title = selected.count > 1 ? "删除 \(selected.count) 项…" : "删除…"
            let delete = menu.addItem(withTitle: title, action: #selector(deleteClicked), keyEquivalent: "")
            delete.target = self; delete.isEnabled = parent.model.canManage(selected)
        }
    }
}

private final class FileTableView: NSTableView {
    var onDropExit: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); onDropExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { onDropExit?() }
        return super.performDragOperation(sender)
    }
}

private final class WorkspaceFileRow: NSTableRowView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(WorkspaceAppearance.line).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        WorkspaceAppearance.orange.withAlphaComponent(isEmphasized ? 0.16 : 0.09).setFill()
        bounds.fill()
    }
}
