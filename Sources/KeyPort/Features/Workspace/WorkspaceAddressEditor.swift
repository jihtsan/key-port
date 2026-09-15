import SwiftUI
import KeyPortInterface

struct WorkspaceAddressEditor: View {
    @Binding var draft: AccessFormDraft
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("管理本次添加的地址").font(.title2)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("先验证第一条地址，其他新增地址保存为待验证路径；共用当前账户和端口。")
                .foregroundStyle(.secondary)
            List(draft.addresses, id: \.self) { value in
                HStack {
                    Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    if value == draft.address {
                        Text("本次验证").foregroundStyle(.secondary)
                    } else {
                        Button("先验证此地址") {
                            let previous = draft.addresses
                            draft.address = value
                            draft.additionalAddresses = previous.filter { $0 != value }
                        }
                    }
                    Button("移除") {
                        let remaining = draft.addresses.filter { $0 != value }
                        draft.address = remaining.first ?? ""
                        draft.additionalAddresses = Array(remaining.dropFirst())
                    }
                }.padding(.vertical, 6)
            }
            HStack {
                TextField("IP 地址或主机名", text: $address).textFieldStyle(.roundedBorder)
                Button("添加地址") {
                    let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.address.isEmpty { draft.address = value }
                    else if !draft.addresses.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { draft.additionalAddresses.append(value) }
                    address = ""
                }.disabled(!AccessFormDraft.isValidHost(address.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }.padding(24).frame(width: 720, height: 440)
    }
}
