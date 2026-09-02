//
//  DualShot_CameraApp.swift
//  DualShot Camera
//
//  App entry: constructs the camera engine + @Observable session model once
//  and injects them into the environment for the SwiftUI layer. Engine
//  construction is fail-soft — a Metal/pipeline init failure shows a minimal
//  error screen instead of crashing at launch.
//

import SwiftUI

@main
struct DualShot_CameraApp: App {

    @State private var model: CameraSessionModel?

    init() {
        do {
            let engine = try CameraSessionEngine(preset: .p1080_30)
            _model = State(initialValue: CameraSessionModel(engine: engine))
        } catch {
            // Logged; the UI shows an availability screen below.
            assertionFailure("CameraSessionEngine init failed: \(error.localizedDescription)")
            _model = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                ContentView()
                    .environment(model)
            } else {
                EngineUnavailableView()
            }
        }
    }
}

/// Shown only if the Metal engine could not be created (never on supported
/// hardware).
private struct EngineUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Camera engine unavailable")
                .font(.headline)
            Text("Metal is required for the dual render pipeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .preferredColorScheme(.dark)
    }
}
