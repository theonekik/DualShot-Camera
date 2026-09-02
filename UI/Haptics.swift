//
//  Haptics.swift
//  DualShot Camera
//
//  Centralized haptic feedback for camera gestures, per Apple HIG guidance
//  (impact generators are lightweight and should be prepared + reused).
//

import UIKit

enum Haptics {

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    /// Prepare all generators once (e.g. on appear) so first-use latency is zero.
    static func prepare() {
        light.prepare()
        medium.prepare()
        rigid.prepare()
    }

    /// Preset pill switch.
    static func presetChanged() {
        light.impactOccurred(intensity: 0.9)
    }

    /// Record button tap (start and stop).
    static func captureTap() {
        medium.impactOccurred(intensity: 1.0)
    }

    /// Recording finalized successfully.
    static func recordingComplete() {
        rigid.impactOccurred(intensity: 1.0)
    }

    /// Generic light tap feedback.
    static func selection() {
        light.impactOccurred(intensity: 0.6)
    }
}
