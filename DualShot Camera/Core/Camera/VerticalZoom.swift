//
//  VerticalZoom.swift
//  DualShot Camera
//
//  The 9:16 portrait zoom state: a 3-way cycle (1.0x → 1.2x → 1.5x). The
//  16:9 landscape pipeline is never affected.
//

import CoreGraphics
import Foundation

/// Zoom scale applied ONLY to the 9:16 portrait target.
///
/// The pipeline consumes `scale` (a plain `CGFloat` crop factor); the enum
/// adds the cycle order and the ultra-compact UI label.
public nonisolated enum VerticalZoomScale: CGFloat, CaseIterable, Identifiable, Sendable, Equatable {
    case oneX = 1.0
    case oneTwoX = 1.2
    case oneFiveX = 1.5

    public var id: CGFloat { rawValue }

    /// The crop scale factor handed to the render pipeline.
    public var scale: CGFloat { rawValue }

    /// Ultra-compact label: "1.0x", "1.2x", "1.5x".
    public var label: String {
        String(format: "%.1fx", rawValue)
    }

    /// Next state in the cycle: 1.0x → 1.2x → 1.5x → 1.0x.
    public var next: VerticalZoomScale {
        switch self {
        case .oneX: .oneTwoX
        case .oneTwoX: .oneFiveX
        case .oneFiveX: .oneX
        }
    }
}
