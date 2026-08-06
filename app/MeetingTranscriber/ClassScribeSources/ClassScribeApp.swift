import SwiftUI

@main
struct ClassScribeApp: App {
    @State private var model = ClassScribeModel()

    init() {
        BuildIdentity.recordLaunch()
    }

    var body: some Scene {
        WindowGroup("ClassScribe") {
            ContentView(model: model)
                .frame(minWidth: 1_080, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
