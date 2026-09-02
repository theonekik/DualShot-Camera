//
//  RecordingHUD.swift
//  DualShot Camera
//
//  Live recording overlay: elapsed time, per-track file sizes, and the
//  measured camera frame rate — all driven by the @Observable view model.
//

import SwiftUI

struct RecordingHUD: View {

    @Environment(CameraSessionModel.self) private var model

    var body: some View {
        Group {
            if model.isRecording {
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                            .shadow(color: .red.opacity(0.8), radius: 3)
                        Text(Self.elapsedText(model.elapsedTime))
                    }
                    Text("L \(Self.megabytes(model.landscapeFileSizeMB))")
                    Text("P \(Self.megabytes(model.portraitFileSizeMB))")
                    Text("\(model.fps) FPS")
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.isRecording)
        .accessibilityElement(children: .combine)
    }

    private static func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func megabytes(_ value: Double) -> String {
        String(format: "%.1f MB", value)
    }
}
