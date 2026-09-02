import SwiftUI

@main
struct DualAspectRecorderApp: App {
    @StateObject private var viewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    await viewModel.prepare()
                }
        }
    }
}
