import AppKit
import PixelLiftCore
import SwiftUI

@MainActor
struct PreferencesView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var token = ""
    @State private var confirmingClear = false

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
            Section("ストレージ") {
                LabeledContent("作業領域", value: sizeText(model.cacheBytes))
                LabeledContent("キャッシュ上限", value: "512 MiB")
                LabeledContent("アプリ本体", value: sizeText(model.bundleBytes))
                Button("キャッシュを削除…") { confirmingClear = true }
                    .disabled(!model.canClearCache)
            }
            Section("API利用状況") {
                LabeledContent("このセッションの開始要求", value: model.cloudRequests.formatted())
                Link("Replicateの処理履歴", destination: URL(string: "https://replicate.com/predictions")!)
                Link("Replicateの請求情報", destination: URL(string: "https://replicate.com/account/billing")!)
            }
            Section("このアプリについて") {
                LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(idealHeight: 580)
        .task {
            while !Task.isCancelled {
                await model.refreshCacheUsage()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
        }
        .confirmationDialog("キャッシュを削除", isPresented: $confirmingClear) {
            Button("一時的な処理結果を削除", role: .destructive, action: model.clearCache)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("プレビューや書き出しに使う一時的な処理結果を削除します。")
        }
        .alert(item: $model.settingsMessage) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
    }

    private func sizeText(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
