import AppKit
import PixelLiftCore
import SwiftUI

@MainActor
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var receivingDrop = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 240, maxWidth: 360)
                preview.frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                inspector.frame(minWidth: 265, idealWidth: 280, maxWidth: 350, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            footer
        }
        .overlay {
            if receivingDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.addImages(files)
            return true
        } isTargeted: { receivingDrop = $0 }
        .confirmationDialog("Replicateに画像を送信", isPresented: $model.confirmingCloud, titleVisibility: .visible) {
            Button("同意して送信", action: model.confirmCloud)
            Button("キャンセル", role: .cancel, action: model.cancelConsent)
        } message: {
            Text("画像\(model.consentCount)件をReplicateのサーバーに送信します。API利用料金が発生する可能性があります。予測データは通常1時間で削除されます。")
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("画像").font(.headline)
                Spacer()
                Button(action: model.openImages) {
                    Label("画像を追加…", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("画像を追加…")
            }.padding(14)
            List(model.images, selection: $model.selectedID) { image in
                HStack(spacing: 9) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(image.status.title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .tag(image.id)
                .contextMenu {
                    if image.status.canCancel { Button("処理をキャンセル") { model.cancel(image.id) } }
                    if image.status.canRetry { Button("同じ設定で再試行") { model.retry(image.id) } }
                    Button("現在の設定で処理") { model.reprocess(image.id) }
                        .disabled(image.status.isEnqueued || model.saving || model.maintainingCache)
                    Button("一覧から取り除く", role: .destructive) { model.remove(image.id) }
                        .disabled(image.status.isEnqueued || model.saving || model.maintainingCache)
                }
            }
            .listStyle(.inset)
        }
    }

    private var preview: some View {
        Group {
            if let item = model.selected {
                ComparePreview(item: item, result: item.result)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("画像をドロップ").font(.title2.weight(.semibold))
                    Text("PNG、JPEG、TIFF、WebP").foregroundStyle(.secondary)
                    Button("Finderから選択…", action: model.openImages).padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
    }

    private var inspector: some View {
        Form {
            Section("処理設定") {
                Picker("プロバイダー", selection: $model.provider) {
                    ForEach(ProviderChoice.allCases) { provider in Text(provider.label).tag(provider) }
                }
                Picker("倍率", selection: $model.scale) {
                    ForEach(UpscaleScale.allCases) { scale in Text("\(scale.rawValue)倍").tag(scale) }
                }
                if model.provider == .replicate {
                    Picker("高画質化モード", selection: $model.mode) {
                        ForEach(model.provider.modes) { mode in Text(mode.title).tag(mode) }
                    }
                    if model.mode == .preserveFaces {
                        Text("顔補正を無効にします。目や輪郭などの変化はプレビューで確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.mode == .enhanceFaces {
                        Text("顔補正により、目や口元などの特徴が変化する場合があります。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Replicateに画像を送信します。API利用料金が発生する場合があります。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Mockはローカル補間で操作を確認するモードです。AI処理は行いません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.scale == .eight && model.provider == .replicate {
                    Text("8倍は1回の処理です。画像サイズによって処理時間と料金が増え、細部が変化する場合があります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("同時実行数", selection: $model.concurrentJobs) {
                    Text("1件").tag(1)
                    Text("2件").tag(2)
                }
            }
            if let item = model.selected {
                Section("選択した画像") {
                    LabeledContent("解像度") {
                        Text("\(item.info.width.formatted(.number.grouping(.never))) × \(item.info.height.formatted(.number.grouping(.never))) px")
                    }
                    LabeledContent("ファイル容量", value: ByteCountFormatter.string(fromByteCount: Int64(item.info.bytes), countStyle: .file))
                    if item.info.frameCount > 1 {
                        Text("1ページ目または先頭フレームのみを使用します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("状態") { Text(item.status.title) }
                    if case .running(let stage) = item.status {
                        Text(stage.title).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .failed(let error) = item.status {
                        Text(error.userText).font(.caption).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if item.status.canCancel {
                        Button("この処理をキャンセル") { model.cancel(item.id) }
                    }
                    if item.status.canRetry {
                        Button("同じ設定で再試行") { model.retry(item.id) }
                            .disabled(model.saving || model.maintainingCache)
                    }
                    if !item.status.isEnqueued, let result = item.result {
                        LabeledContent(item.status.canRetry ? "前回の処理結果" : "処理結果") {
                            Text("\(result.info.width.formatted(.number.grouping(.never))) × \(result.info.height.formatted(.number.grouping(.never))) px")
                        }
                        LabeledContent("処理済みプロバイダー", value: result.provider)
                        Button("選択した結果を保存…", action: model.saveSelected)
                            .disabled(!model.canSave)
                        Button("現在の設定でもう一度処理") { model.reprocess(item.id) }
                            .disabled(model.saving || model.maintainingCache)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.busy || model.saving { ProgressView().controlSize(.small) }
            if model.saving {
                Text("保存中")
            } else {
                Text("待ち \(model.waitingCount)件・処理中 \(model.runningCount)件・完了 \(model.completedCount)件・失敗 \(model.failedCount)件")
                    .font(.callout)
            }
            Spacer()
            if model.busy { Button("すべてキャンセル", action: model.cancelAll) }
            Button("すべての結果を保存…", action: model.saveAll)
                .disabled(!model.canSave || model.resultCount == 0)
            Button("未処理\(model.readyCount)件を開始", action: model.start)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
        }.padding(12)
    }
}
