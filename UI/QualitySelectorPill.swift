//
//  QualitySelectorPill.swift
//  DualShot Camera
//
//  Capsule preset picker with a sliding selection indicator
//  (matchedGeometryEffect) and light haptic feedback on switch.
//

import SwiftUI

struct QualitySelectorPill: View {

    @Environment(CameraSessionModel.self) private var model
    @Namespace private var selectionNamespace

    private let options: [QualityPreset] = [.p1080_30, .p1080_60, .p4k_30]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.preset)
    }

    private func segment(for option: QualityPreset) -> some View {
        let isSelected = model.preset == option
        return Text(Self.label(for: option))
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white)
                        .matchedGeometryEffect(id: "presetSelection", in: selectionNamespace)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                Haptics.presetChanged()
                Task { try? await model.selectPreset(option) }
            }
    }

    static func label(for preset: QualityPreset) -> String {
        switch preset {
        case .p1080_30: "1080p 30"
        case .p1080_60: "1080p 60"
        case .p4k_30: "4K 30"
        }
    }
}
