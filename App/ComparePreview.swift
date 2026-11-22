import AppKit
import PixelLiftCore
import SwiftUI

struct RenderedResult: Equatable, Sendable {
    let ticket: ResultCache.Ticket
    var url: URL { ticket.output }
    let info: ImageInfo
    let scale: UpscaleScale
    let provider: String
}

private enum PreviewZoom: Int, CaseIterable, Identifiable {
    case fit = 0, actual = 100, double = 200, quadruple = 400
    var id: Int { rawValue }

    var title: LocalizedStringKey {
        self == .fit ? "全体にフィット" : "\(rawValue.formatted(.number.grouping(.never)))%"
    }
}

@MainActor
struct ComparePreview: View {
    let item: WorkspaceImage
    let result: RenderedResult?

    @Environment(\.displayScale) private var displayScale
    @State private var zoom: PreviewZoom = .fit
    @State private var separation = 0.5
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @State private var layers: Layers?
    @State private var failed = false

    private struct LoadKey: Equatable {
        let item: UUID
        let result: URL?
        let fullResolution: Bool
    }

    private struct Layers: Sendable {
        let original: CGImage
        let processed: CGImage?
    }

    private var loadKey: LoadKey {
        LoadKey(item: item.id, result: result?.url, fullResolution: zoom != .fit)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("表示倍率", selection: $zoom) {
                    ForEach(PreviewZoom.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                if zoom != .fit {
                    Text(result == nil ? "倍率は元画像基準" : "倍率は処理結果基準")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if result != nil {
                    Label("比較表示", systemImage: "rectangle.split.2x1")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            GeometryReader { geometry in
                if let layers {
                    comparison(layers, viewport: geometry.size)
                } else if failed {
                    ContentUnavailableView("プレビューを表示できません", systemImage: "photo.badge.exclamationmark")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("プレビューを読み込み中")
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()
            if result != nil {
                Divider()
                HStack(spacing: 12) {
                    Text("元画像")
                    Slider(value: $separation, in: 0...1)
                        .accessibilityLabel("元画像と処理後の境界")
                    Text("処理後")
                }
                .font(.caption)
                .padding(12)
            }
        }
        .task(id: loadKey) { await load(loadKey) }
        .onChange(of: item.id) { _, _ in
            zoom = .fit
            separation = 0.5
            pan = .zero
        }
        .onChange(of: zoom) { _, _ in pan = .zero }
        .onChange(of: result?.url) { _, _ in pan = .zero }
    }

    private func comparison(_ layers: Layers, viewport: CGSize) -> some View {
        let info = result?.info ?? item.info
        let width = CGFloat(info.width)
        let height = CGFloat(info.height)
        let ratio = zoom == .fit
            ? min(max(1, viewport.width - 32) / width, max(1, viewport.height - 32) / height)
            : CGFloat(zoom.rawValue) / 100 / displayScale
        let picture = CGSize(width: width * ratio, height: height * ratio)
        let translated = limit(CGSize(width: pan.width + drag.width, height: pan.height + drag.height),
                               picture: picture, viewport: viewport)
        let origin = CGPoint(x: (viewport.width - picture.width) / 2 + translated.width,
                             y: (viewport.height - picture.height) / 2 + translated.height)
        let bounds = CGRect(origin: CGPoint(x: (origin.x * displayScale).rounded() / displayScale,
                                            y: (origin.y * displayScale).rounded() / displayScale),
                            size: picture)

        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let before = Image(decorative: layers.original, scale: 1)
                    .interpolation(zoom == .fit ? .high : .none)
                context.draw(before, in: bounds)
                if let processed = layers.processed {
                    let edge = size.width * separation
                    var afterContext = context
                    afterContext.clip(to: Path(CGRect(x: edge, y: 0, width: size.width - edge, height: size.height)))
                    let after = Image(decorative: processed, scale: 1)
                        .interpolation(zoom == .fit ? .high : .none)
                    afterContext.draw(after, in: bounds)
                }
            }
            .accessibilityLabel(layers.processed == nil ? "元画像プレビュー" : "元画像と処理結果の比較プレビュー")
            .contentShape(Rectangle())
            .gesture(DragGesture()
                .updating($drag) { value, state, _ in if zoom != .fit { state = value.translation } }
                .onEnded { value in
                    guard zoom != .fit else { return }
                    pan = limit(CGSize(width: pan.width + value.translation.width,
                                       height: pan.height + value.translation.height),
                                picture: picture, viewport: viewport)
                })
            if layers.processed != nil {
                Rectangle().fill(.white.opacity(0.9))
                    .frame(width: 1, height: viewport.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: separation * viewport.width, y: viewport.height / 2)
                    .allowsHitTesting(false)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .position(x: separation * viewport.width, y: viewport.height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("comparison"))
                        .onChanged { value in
                            guard viewport.width > 0 else { return }
                            separation = min(1, max(0, value.location.x / viewport.width))
                        })
                    .accessibilityHidden(true)
            }
        }
        .coordinateSpace(name: "comparison")
    }

    private func limit(_ offset: CGSize, picture: CGSize, viewport: CGSize) -> CGSize {
        let horizontal = max(0, (picture.width - viewport.width) / 2)
        let vertical = max(0, (picture.height - viewport.height) / 2)
        return CGSize(width: min(horizontal, max(-horizontal, offset.width)),
                      height: min(vertical, max(-vertical, offset.height)))
    }

    private func load(_ key: LoadKey) async {
        let url = item.url
        let before = item.info
        let after = result
        layers = nil
        failed = false
        let operation = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try autoreleasepool {
                try Task.checkCancellation()
                let original = try key.fullResolution
                    ? ImageFiles.pixels(url, info: before)
                    : ImageFiles.preview(url, maxSide: 2400)
                try Task.checkCancellation()
                let processed = try after.map { output in
                    try key.fullResolution
                        ? ImageFiles.pixels(output.url, info: output.info)
                        : ImageFiles.preview(output.url, maxSide: 2400)
                }
                return Layers(original: original, processed: processed)
            }
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            try Task.checkCancellation()
            layers = loaded
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
