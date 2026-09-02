//
//  DualPreviewCard.swift
//  DualShot Camera
//
//  A glassmorphic preview card: rounded corners, gradient hairline stroke,
//  soft drop shadow, a ratio badge, and a live MTKView preview inside.
//

import SwiftUI

/// Shared card chrome for both live previews.
struct DualPreviewCard: View {

    let kind: PreviewKind
    let title: String

    @Environment(CameraSessionModel.self) private var model

    private let cornerRadius: CGFloat = 24

    var body: some View {
        Group {
            if streamIsActive {
                DualPreviewMetalView(
                    kind: kind,
                    isLive: model.isLive,
                    preferredFPS: model.preset.frameRate
                ) {
                    switch kind {
                    case .landscape: model.preview?.landscapeBuffer
                    case .portrait: model.preview?.portraitBuffer
                    }
                }
            } else {
                streamOffPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .background(backgroundGradient)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(glassStroke)
        .overlay(glassSheen)
        .overlay(alignment: .topLeading) { badge }
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 10)
    }

    /// Whether this card's stream is enabled (drives live preview + recording).
    private var streamIsActive: Bool {
        switch kind {
        case .landscape: model.isLandscapeActive
        case .portrait: model.isPortraitActive
        }
    }

    /// Shown while the stream is toggled off: the live preview is replaced by
    /// a dimmed placeholder so "turning off" is immediately visible. The
    /// stream's writer is also bypassed on the next recording.
    private var streamOffPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
            Text("STREAM OFF")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            Text("Recording will skip this stream")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var badgeDotColor: Color {
        if !streamIsActive { return Color.red.opacity(0.85) }
        return model.isLive ? Color.green.opacity(0.95) : Color.gray.opacity(0.6)
    }

    // MARK: - Chrome

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.09),
                Color(red: 0.02, green: 0.02, blue: 0.04),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var glassStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(0.32),
                        .white.opacity(0.06),
                        .white.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var glassSheen: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.08), .clear, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
    }

    private var badge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeDotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .padding(10)
    }
}

// MARK: - Preview aspect helpers

extension PreviewKind {
    /// Target aspect ratio for layout sizing.
    var aspectRatio: CGFloat {
        switch self {
        case .landscape: 16.0 / 9.0
        case .portrait: 9.0 / 16.0
        }
    }

    var label: String {
        switch self {
        case .landscape: "16:9 LANDSCAPE"
        case .portrait: "9:16 PORTRAIT"
        }
    }
}
