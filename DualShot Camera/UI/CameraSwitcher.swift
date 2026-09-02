//
//  CameraSwitcher.swift
//  DualShot Camera
//
//  Glassmorphic floating control: camera flip (front/rear) + Cinematic Mode
//  pill toggle. Both controls drive the @Observable view model and give
//  haptic feedback; the live previews update automatically.
//

import SwiftUI

struct CameraSwitcher: View {

    @Environment(CameraSessionModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            flipButton
            Divider()
                .frame(height: 20)
                .overlay(.white.opacity(0.15))
            cinematicPill
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.isCinematicActive)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Camera flip

    private var flipButton: some View {
        Button {
            Haptics.captureTap()
            Task { await model.flipCamera() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isLive)
        .opacity(model.isLive ? 1 : 0.4)
        .accessibilityLabel("Switch camera")
        .accessibilityValue(model.isFrontCamera ? "Front camera" : "Back camera")
    }

    // MARK: - Cinematic pill

    private var cinematicPill: some View {
        Button {
            Haptics.selection()
            Task { await model.toggleCinematic() }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isCinematicActive ? Color.orange : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .shadow(color: model.isCinematicActive ? .orange.opacity(0.9) : .clear, radius: 3)
                Text(model.isCinematicActive ? "CINEMATIC" : "STANDARD")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(model.isCinematicActive ? Color.orange : Color.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(model.isCinematicActive ? Color.orange.opacity(0.18) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(
                    model.isCinematicActive ? Color.orange.opacity(0.5) : Color.white.opacity(0.12),
                    lineWidth: 0.8
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.isLive)
        .opacity(model.isLive ? 1 : 0.4)
        .accessibilityLabel("Cinematic mode")
        .accessibilityValue(model.isCinematicActive ? "On" : "Off")
    }
}
