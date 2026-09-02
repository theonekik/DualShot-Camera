//
//  AboutView.swift
//  DualShot Camera
//
//  Lightweight "About" sheet: app identity, dual-stream capture description,
//  vertical crop scale status, and a credit footer. Presented by the info (i)
//  button on the top overlay (see CameraOverlayView.swift).
//

import SwiftUI

struct AboutView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(CameraSessionModel.self) private var model

    /// TODO: replace with your support / credits URL.
    private let creditURL = URL(string: "https://github.com/")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    description
                    scaleCard
                    credits
                }
                .padding(24)
            }
            .background(background)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(
                        colors: [.orange, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .shadow(color: .orange.opacity(0.35), radius: 16, y: 6)
            VStack(spacing: 4) {
                Text("DualShot Camera")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("v1.0")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
    }

    private var description: some View {
        Text("Records two videos simultaneously from a single camera sensor — a 16:9 landscape master and a 9:16 portrait crop — in hardware-accelerated HEVC, with independent stream toggles so you capture exactly what you need.")
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
    }

    private var scaleCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.square")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Vertical Crop Scale")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Supported: 1.0x · 1.2x · 1.5x  —  current \(model.verticalZoomScale.label)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private var credits: some View {
        VStack(spacing: 10) {
            Text("Built with SwiftUI · AVFoundation · Metal")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            if let creditURL {
                Link(destination: creditURL) {
                    Label("Credits & Feedback", systemImage: "link")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.orange.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

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
}