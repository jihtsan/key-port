import AppKit
import KeyPortCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("KeyPort.clipboardClearSeconds") private var clipboardClearSeconds = 30.0
    @AppStorage("KeyPort.cloudSyncEnabled") private var cloudSyncEnabled = false
    @AppStorage("KeyPort.defaultPasswordSync") private var defaultPasswordSync = false
    @AppStorage(UserDefaultsNetworkHintSettings.key) private var networkHintEnabled = false
    @State private var archivePassword = ""
    @State private var networkHintStatus: NetworkHintResult = .disabled

    var body: some View {
        TabView {
            Form {
                Section("设备") {
                    LabeledContent("当前设备", value: model.currentDevice?.name ?? "未注册")
                    LabeledContent("设备 ID", value: model.currentDevice?.id ?? "不可用")
                }
                Section("SSH 文件") {
                    LabeledContent("托管配置", value: "~/.ssh/keyport/config")
                    LabeledContent("已知主机", value: "~/.ssh/keyport/known_hosts")
                }
                Section("网络提示") {
                    Toggle("记录私网连接的 Wi-Fi 名称", isOn: $networkHintEnabled)
                    LabeledContent("权限状态") {
                        Label(networkHintStatus.displayTitle, systemImage: networkHintStatus.systemImage)
                    }
                    Text("仅保存在本机连接记录中，不影响 SSH 或服务访问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if networkHintStatus.needsLocationSettings {
                        Button {
                            openLocationSettings()
                        } label: {
                            Label("打开位置服务设置", systemImage: "gearshape")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Section("元数据") {
                    Toggle("通过 iCloud 同步非敏感元数据", isOn: $cloudSyncEnabled)
                    LabeledContent("状态") {
                        HStack(spacing: 6) {
                            if model.cloudState == .checking || model.cloudState == .syncing {
                                ProgressView().controlSize(.small)
                            }
                            Label(model.cloudState.title, systemImage: model.cloudState.systemImage)
                        }
                    }
                    if let detail = model.cloudState.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let lastCloudSyncAt = model.lastCloudSyncAt {
                        LabeledContent("上次同步", value: lastCloudSyncAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button {
                        Task { await model.synchronizeCloud() }
                    } label: {
                        Label("立即同步", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    }
                        .disabled(!cloudSyncEnabled || model.isBusy)
                }
                Section("密码") {
                    Toggle("新密码默认使用 iCloud Keychain", isOn: $defaultPasswordSync)
                        .disabled(!model.canSynchronizePasswords)
                    if !model.canSynchronizePasswords {
                        Label("此版本无法使用 iCloud Keychain 同步", systemImage: "icloud.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("服务器密码作为 Keychain 项目保存，绝不会包含在 CloudKit 元数据中。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("同步", systemImage: "icloud") }

            Form {
                Section("本地身份验证") {
                    Text("访问密码和批量启用免密需要使用 Touch ID 或 Mac 登录密码。")
                }
                Section("剪贴板") {
                    Stepper("在 \(Int(clipboardClearSeconds)) 秒后清除已复制的敏感内容", value: $clipboardClearSeconds, in: 10...120, step: 10)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("安全性", systemImage: "lock.shield") }

            Form {
                Section("加密元数据归档") {
                    SecureField("恢复密码", text: $archivePassword)
                    HStack {
                        Button("导出") { Task { await model.exportMetadata(password: archivePassword) } }
                        Button("导入") { Task { await model.importMetadata(password: archivePassword) } }
                    }
                    .disabled(archivePassword.isEmpty || model.isBusy)
                }
                Section("内容") {
                    LabeledContent("包含", value: "服务器、别名、公钥、设备、授权")
                    LabeledContent("不包含", value: "密码、私钥、本地路径、审计日志")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("归档", systemImage: "archivebox") }
        }
        .padding(10)
        .onAppear {
            if !model.canSynchronizePasswords {
                defaultPasswordSync = false
            }
        }
        .onChange(of: cloudSyncEnabled) { _, enabled in
            model.cloudSyncSettingChanged(enabled)
        }
        .task(id: networkHintEnabled) {
            await updateNetworkHintStatus()
        }
    }

    private func updateNetworkHintStatus() async {
        let settings = UserDefaultsNetworkHintSettings()
        networkHintStatus = await SystemNetworkHintProvider(settings: settings).currentSSID()
    }

    private func openLocationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private extension NetworkHintResult {
    var displayTitle: String {
        switch self {
        case .available: "可用"
        case .disabled: "已关闭"
        case .notDetermined: "尚未授权"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        case .servicesDisabled: "系统服务已关闭"
        case .unavailable: "不可用"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle"
        case .disabled: "minus.circle"
        case .notDetermined: "questionmark.circle"
        case .denied, .restricted, .servicesDisabled: "location.slash"
        case .unavailable: "wifi.slash"
        }
    }

    var needsLocationSettings: Bool {
        switch self {
        case .notDetermined, .denied, .restricted, .servicesDisabled: true
        case .available, .disabled, .unavailable: false
        }
    }
}
