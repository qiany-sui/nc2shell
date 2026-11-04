import SwiftUI
import Nc2ShellCore

struct RemotePermissionEdit: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let directory: String
    let connectionID: UUID
    let revision: UUID
    let server: String
}

struct RemotePermissionsView: View {
    @ObservedObject var model: RemoteFilesModel
    let edit: RemotePermissionEdit
    @Environment(\.dismiss) private var dismiss
    @State private var octal: String

    init(model: RemoteFilesModel, edit: RemotePermissionEdit) {
        self.model = model; self.edit = edit
        _octal = State(initialValue: String(format: "%03o", edit.file.mode & 0o777))
    }

    private var permissions: UInt32? { try? RemotePermissions.parse(octal) }
    private var isCurrent: Bool {
        model.connectionID == edit.connectionID && model.path == edit.directory && model.locationRevision == edit.revision && model.canManage([edit.file])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改远程权限").font(.title2.bold())
            Text(verbatim: "服务器：" + edit.server).font(.caption)
            Text(verbatim: RemoteFile.join(edit.directory, edit.file.name)).textSelection(.enabled).lineLimit(3)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                GridRow {
                    Text("用户")
                    Text("读取")
                    Text("写入")
                    Text("执行")
                }.font(.headline)
                permissionRow("所有者", shift: 6)
                permissionRow("组", shift: 3)
                permissionRow("其他用户", shift: 0)
            }.padding(.vertical, 8)
            HStack {
                Text("八进制权限")
                TextField("000–777", text: $octal).textFieldStyle(.roundedBorder).frame(width: 90)
                    .accessibilityLabel("八进制权限")
                if let permissions, let mode = try? RemotePermissions.mode(original: edit.file.mode, permissions: permissions) {
                    Text(String(format: "%04o → %04o", edit.file.mode & 0o7777, mode)).font(.system(.body, design: .monospaced))
                }
            }
            if permissions == nil { Text("请输入三位八进制数（000–777）。").font(.caption).foregroundStyle(.red) }
            Text("仅修改此项，不影响文件夹内的内容。已有特殊权限位保持不变；减少权限可能使此项无法访问。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !isCurrent { Text("目录、连接或文件状态已变化，请关闭后重新选择。").font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用权限") {
                    model.setPermissions(edit.file, to: octal, expectedPath: edit.directory, connectionID: edit.connectionID, revision: edit.revision)
                    dismiss()
                }.disabled(!isCurrent || permissions == nil || permissions == edit.file.mode & 0o777)
            }
        }.padding(24).frame(width: 500)
    }

    private func permissionRow(_ name: String, shift: UInt32) -> some View {
        GridRow {
            Text(name)
            permissionToggle(name + "读取", bit: 4 << shift)
            permissionToggle(name + "写入", bit: 2 << shift)
            permissionToggle(name + "执行", bit: 1 << shift)
        }
    }

    private func permissionToggle(_ label: String, bit: UInt32) -> some View {
        Toggle(label, isOn: Binding(get: { (permissions ?? edit.file.mode) & bit != 0 }, set: { checked in
            guard let permissions else { return }
            octal = String(format: "%03o", checked ? permissions | bit : permissions & ~bit)
        })).labelsHidden().toggleStyle(.checkbox).accessibilityLabel(label).disabled(permissions == nil)
    }
}
