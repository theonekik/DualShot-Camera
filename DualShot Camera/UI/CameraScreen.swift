//
//  CameraScreen.swift
//  DualShot Camera
//
//  The single-screen camera UI: dual live preview cards (16:9 above, 9:16
//  below), preset pill, recording HUD, and the record button — dark-mode
//  optimized, driven entirely by `CameraSessionModel` (@Observable).
//

import SwiftUI

struct CameraScreen: View {

    @Environment(CameraSessionModel.self) private var model

    var body: some View {
        ZStack {
            background

            VStack(spacing: 14) {
                topBar
                    .padding(.top, 8)

                CameraSwitcher()

                DualPreviewCard(kind: .landscape, title: PreviewKind.landscape.label)
                    .aspectRatio(PreviewKind.landscape.aspectRatio, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        CameraOverlayView(kind: .landscape)
                            .padding(10)
                    }

                DualPreviewCard(kind: .portrait, title: PreviewKind.portrait.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(PreviewKind.portrait.aspectRatio, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        VStack(spacing: 8) {
                            CameraOverlayView(kind: .portrait)
                            portraitZoomButton
                        }
                        .padding(10)
                    }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            // Controls overlay.
            VStack {
                Spacer()
                RecordingHUD()
                    .padding(.bottom, 12)
                RecordButton()
                    .padding(.bottom, 18)
            }

            if model.state.phase == .error {
                errorBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let warning = model.warningMessage {
                warningBanner(warning)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let toast = model.toastMessage {
                cinematicToast(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(6)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toastMessage)
        .onAppear {
            Haptics.prepare()
            model.cleanupTemporaryFiles()
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.02, green: 0.025, blue: 0.045),
                Color(red: 0.0, green: 0.0, blue: 0.01),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DUALSHOT")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(3.5)
                    .foregroundStyle(.white.opacity(0.95))
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor.opacity(0.85))
            }
            Spacer()
            QualitySelectorPill()
            CameraInfoButton()
        }
    }

    private var statusText: String {
        switch model.state.phase {
        case .idle: "STANDBY"
        case .configuring: "CONFIGURING…"
        case .previewing: "LIVE PREVIEW"
        case .recording: "REC ● \(QualitySelectorPill.label(for: model.preset))"
        case .processing: "FINALIZING…"
        case .error: "ERROR"
        }
    }

    private var statusColor: Color {
        switch model.state.phase {
        case .recording: .red
        case .previewing: .green
        case .error: .orange
        default: .white
        }
    }

    // MARK: - Error banner

    private var errorBanner: some View {
        VStack(spacing: 6) {
            Label("Camera Error", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text(model.state.associatedError.map { Self.errorText($0) } ?? "Unknown error")
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private static func errorText(_ error: CameraError) -> String {
        switch error {
        case .permissionDenied: "Camera access denied. Enable it in Settings to record."
        case .configurationFailed(let reason): "Configuration failed: \(reason)"
        case .sessionInterrupted(let reason): "Session interrupted: \(reason)"
        case .writerFailed(let reason): "Writer failed: \(reason)"
        case .renderFailed(let reason): "Render failed: \(reason)"
        case .invalidStateTransition(let from, let to): "Invalid transition \(from) → \(to)"
        case .unknown(let reason): reason
        }
    }

    // MARK: - Portrait zoom pill

    /// Ultra-compact glassmorphic cycle control for the 9:16 portrait zoom:
    /// 1.0x → 1.2x → 1.5x → 1.0x. Shows only the multiplier; highlighted in
    /// orange while zoomed. Rides the top-trailing corner of the portrait card
    /// (the ratio badge is top-leading, so nothing overlaps); light haptic on
    /// each tap. The 16:9 landscape pipeline is never affected.
    private var portraitZoomButton: some View {
        let zoomed = model.verticalZoomScale != .oneX
        return Button {
            Haptics.selection()
            model.cycleVerticalZoom()
        } label: {
            Text(model.verticalZoomScale.label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(zoomed ? Color.orange : Color.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        zoomed ? Color.orange.opacity(0.55) : Color.white.opacity(0.18),
                        lineWidth: 0.8
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!model.isLive)
        .opacity(model.isLive ? 1 : 0.4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.verticalZoomScale)
        .accessibilityLabel("Portrait zoom")
        .accessibilityValue(model.verticalZoomScale.label)
    }

    // MARK: - Cinematic toast

    /// Subtle floating glassmorphic toast (e.g. Cinematic auto-adjusted the
    /// capture format to gain depth support). Auto-dismisses via the model.
    private func cinematicToast(_ message: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .shadow(color: .orange.opacity(0.9), radius: 3)
            Text(message)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 124)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Warning banner

    private func warningBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Button {
                model.dismissWarning()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
