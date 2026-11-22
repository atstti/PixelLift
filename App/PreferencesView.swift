import AppKit
import PixelLiftCore
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var token = ""

    var body: some View {
        Form {
            Section("クラウド処理") {
                Picker("APIプロバイダー", selection: $model.provider) {
                    ForEach(ProviderChoice.allCases) { choice in Text(choice.label).tag(choice) }
                }
                SecureField("Replicate APIキー", text: $token)
                HStack {
                    Button("キーチェーンに保存") { if model.saveToken(token) { token = "" } }
                        .disabled(token.isEmpty)
                    Button("削除", action: model.removeToken).disabled(!model.tokenSaved)
                    Text(model.tokenSaved ? "保存済み" : "未設定")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link("ReplicateのAPIキー", destination: URL(string: "https://replicate.com/account/api-tokens")!)
                }
            }
            Section("書き出し") {
                Picker("ファイル形式", selection: $model.exportFormat) {
                    ForEach(ExportFormat.allCases) { format in Text(format.rawValue.uppercased()).tag(format) }
                }
                if model.exportFormat == .jpeg {
                    Slider(value: $model.jpegQuality, in: 0.05...1, step: 0.01) {
                        Text("JPEG品質")
                    } minimumValueLabel: {
                        Text("5%")
                    } maximumValueLabel: {
                        Text(model.jpegQuality.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
                HStack {
                    Button("保存先を選択…", action: model.chooseExportFolder)
                    if let folder = model.exportFolder {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Button("解除", action: model.clearExportFolder)
                    } else {
                        Text("保存時に選択").foregroundStyle(.secondary)
                    }
                }
            }
            Section("API利用状況") {
                Link("Replicateの処理履歴", destination: URL(string: "https://replicate.com/predictions")!)
                Link("Replicateの請求情報", destination: URL(string: "https://replicate.com/account/billing")!)
            }
            Section("このアプリについて") {
                LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(idealHeight: 580)
        .alert(item: $model.settingsMessage) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
    }
}
