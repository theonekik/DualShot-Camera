//
//  CameraOverlayView.swift
//  DualShot Camera
//
//  Stream-toggle overlay controls for each live preview card plus the top-bar
//  info button that presents the About sheet.
//
//  Each card gets ONE compact circular camera toggle (no text label — the
//  stream identity lives in the card's ratio badge). Tap to turn the stream's
//  video on/off.
//
//  Integration (CameraScreen.swift):
//    • topBar: append CameraInfoButton() to the trailing edge of the HStack.
//    • Landscape card:
//        .overlay(alignment: .topTrailing) { CameraOverlayView(kind: .landscape).padding(10) }
//    • Portrait card:
//        .overlay(alignment: .topTrailing) {
//            HStack(spacing: 8) { portraitZoomButton; CameraOverlayView(kind: .portrait) }.padding(10)
//        }
//
//  Toggling a stream off ALSO switches that card's live preview to an "OFF"
//  placeholder (see DualPreviewCard) and bypasses the stream's writer on the
//  next recording. Toggles are disabled only while recording.
//

import SwiftUI

/// Compact circular stream toggle for one preview card. A clean camera icon:
/// video.fill (green ring) when the stream is live, video.slash.fill (red
/// ring) when it is off. The model enforces that at least one stream stays
/// active.
struct CameraOverlayView: View {

    let kind: PreviewKind

    @Environment(CameraSessionModel.self) private var model

    private var isActive: Bool {
        switch kind {
        case .landscape: model.isLandscapeActive
        case .portrait: model.isPortraitActive
        }
    }

    var body: some View {
        Button(action: toggle) {
            toggleLabel
        }
        .buttonStyle(.plain)
        .disabled(model.isRecording)
        .accessibilityLabel(toggleAccessibilityLabel)
        .accessibilityValue(isActive ? "Active" : "Off")
        .accessibilityHint(toggleAccessibilityHint)
    }

    // MARK: - Label (kept small so the type-checker stays fast)

    private var toggleLabel: some View {
        Image(systemName: isActive ? "video.fill" : "video.slash.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 30, height: 30)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(strokeColor, lineWidth: 0.8))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
    }

    private var strokeColor: Color {
        isActive ? Color.green.opacity(0.55) : Color.red.opacity(0.6)
    }

    private var foregroundColor: Color {
        isActive ? Color.white.opacity(0.95) : Color.red.opacity(0.85)
    }

    private var toggleAccessibilityLabel: String {
        "\(kind.shortLabel) stream"
    }

    private var toggleAccessibilityHint: String {
        isActive ? "Double-tap to turn off this stream" : "Double-tap to turn on this stream"
    }

    // MARK: - Action

    private func toggle() {
        Haptics.selection()
        switch kind {
        case .landscape: model.setLandscapeActive(!model.isLandscapeActive)
        case .portrait: model.setPortraitActive(!model.isPortraitActive)
        }
    }
}

/// Small info (i) button on the top overlay that presents the About sheet.
struct CameraInfoButton: View {

    @State private var showsAbout = false

    var body: some View {
        Button {
            Haptics.selection()
            showsAbout = true
        } label: {
            infoIcon
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About DualShot Camera")
        .sheet(isPresented: $showsAbout) {
            AboutView()
        }
    }

    private var infoIcon: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

private extension PreviewKind {
    /// Compact ratio label used only for accessibility (not rendered).
    var shortLabel: String {
        switch self {
        case .landscape: "16:9"
        case .portrait: "9:16"
        }
    }
}