import SwiftUI

@main
@MainActor
struct PixelLiftAIApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        Window("PixelLift AI", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1250, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("画像を開く…", action: model.openImages)
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            PreferencesView(model: model)
                .frame(width: 520)
        }
    }
}
