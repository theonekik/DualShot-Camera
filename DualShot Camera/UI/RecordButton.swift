//
//  RecordButton.swift
//  DualShot Camera
//
//  Aesthetic record control: glowing outer ring, white body at rest, red body
//  with a tactile pulse while recording, and a square "stop" glyph.
//

import SwiftUI

struct RecordButton: View {

    @Environment(CameraSessionModel.self) private var model
    @State private var pulsing = false

    var body: some View {
        Button(action: toggleRecording) {
            ZStack {
                // Glowing outer ring.
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.95), .white.opacity(0.30)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 2.5
                    )
                    .frame(width: 80, height: 80)
                    .shadow(
                        color: model.isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.35),
                        radius: pulsing ? 20 : 7
                    )

                // Body.
                Circle()
                    .fill(model.isRecording ? Color.red : Color.white)
                    .frame(width: 66, height: 66)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 5)

                // Inner glyph: record dot at rest, stop square while recording.
                RoundedRectangle(cornerRadius: model.isRecording ? 5 : 22, style: .continuous)
                    .fill(model.isRecording ? Color.white : Color.black.opacity(0.88))
                    .frame(width: model.isRecording ? 26 : 46, height: model.isRecording ? 26 : 46)
            }
            .scaleEffect(pulsing ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")
        .onChange(of: model.isRecording) { _, recording in
            pulsing = recording
        }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
    }

    private func toggleRecording() {
        Haptics.captureTap()
        Task {
            if model.isRecording {
                let result = try? await model.stopRecording()
                if result != nil {
                    Haptics.recordingComplete()
                }
            } else {
                try? await model.startRecording()
            }
        }
    }
}
