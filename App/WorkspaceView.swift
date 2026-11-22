import AppKit
import PixelLiftCore
import SwiftUI

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
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("画像はReplicateのサーバーに送信され、API利用料金が発生する可能性があります。")
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
                        Text("\(image.info.width.formatted(.number.grouping(.never))) × \(image.info.height.formatted(.number.grouping(.never))) px")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .tag(image.id)
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
                    Picker("モード", selection: $model.mode) {
                        ForEach(UpscaleMode.allCases) { mode in Text(mode.title).tag(mode) }
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
                if model.scale == .eight {
                    Text("8倍は1回の処理です。画像サイズによって処理時間と料金が増え、細部が変化する場合があります。")
                        .font(.caption).foregroundStyle(.secondary)
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
                    if let result = item.result {
                        LabeledContent("処理結果") {
                            Text("\(result.info.width.formatted(.number.grouping(.never))) × \(result.info.height.formatted(.number.grouping(.never))) px")
                        }
                        LabeledContent("処理済みプロバイダー", value: result.provider)
                        Button("選択した結果を保存…", action: model.saveSelected)
                            .disabled(model.saving)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.processing || model.saving { ProgressView().controlSize(.small) }
            if let stage = model.stage { Text(stage.title) }
            if model.saving { Text("保存中") }
            Spacer()
            Button("処理を開始", action: model.start)
                .buttonStyle(.borderedProminent)
                .disabled(model.selected == nil || model.processing)
        }.padding(12)
    }
}
