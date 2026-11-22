import AppKit
import PixelLiftCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack {
                    Button("画像を追加…", action: model.openImages)
                    List(model.images, selection: $model.selectedID) { image in
                        VStack(alignment: .leading) {
                            Text(image.url.lastPathComponent).lineLimit(1)
                            Text("\(image.info.width) × \(image.info.height) px")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(image.id)
                    }
                }.frame(minWidth: 220)
                Group {
                    if let item = model.selected, let picture = try? ImageFiles.preview(item.url, maxSide: 1300) {
                        Image(decorative: picture, scale: 1).resizable().scaledToFit().padding()
                    } else {
                        ContentUnavailableView("画像を追加", systemImage: "photo.on.rectangle", description: Text("Finderから画像をドラッグ＆ドロップ"))
                    }
                }
                .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in
                    model.addImages(urls.filter(\.isFileURL))
                    return true
                }
                Form {
                    Picker("倍率", selection: $model.scale) {
                        ForEach(UpscaleScale.allCases) { scale in Text("\(scale.rawValue)倍").tag(scale) }
                    }
                    Text("Mockはローカル補間のみです。")
                }.padding().frame(minWidth: 240)
            }
            Divider()
            HStack {
                if model.processing { ProgressView().controlSize(.small) }
                if model.mockResult != nil { Text("処理完了") }
                Spacer()
                Button("処理を開始", action: model.start)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected == nil || model.processing)
            }.padding()
        }
        .alert(item: $model.message) { message in
            Alert(title: Text(message.title), message: Text(message.text))
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        Form {
            Text("Mock（APIキー不要）")
            Text("PixelLift AI")
        }.padding()
    }
}
