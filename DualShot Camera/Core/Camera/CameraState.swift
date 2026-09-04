//
//  CameraState.swift
//  DualShot Camera
//
//  The capture pipeline's global state model. `CameraState` is a value type
//  (Sendable + Equatable) so it can be read from any thread; the single
//  mutable copy lives in `CameraStateMachine` (see CameraStateMachine.swift).
//

import Foundation

/// Payload-free projection of `CameraState`, used for transition validation
/// and for UI switches that do not care about error details.
public nonisolated enum CameraPhase: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case idle
    case configuring
    case previewing
    case recording
    case processing
    case error

    public var description: String { rawValue }
}

/// The global camera pipeline state.
public nonisolated enum CameraState: Sendable, Equatable, CustomStringConvertible {
    /// No session, nothing configured.
    case idle
    /// Session is being built/reconfigured for a preset.
    case configuring
    /// Session is live; frames are flowing to the preview/render pipeline.
    case previewing
    /// Dual recording is in progress.
    case recording
    /// Recording stopped; finalizing both output files.
    case processing
    /// The pipeline failed; `associatedError` carries the details.
    case error(CameraError)

    /// Phase ignoring any payload.
    public var phase: CameraPhase {
        switch self {
        case .idle: .idle
        case .configuring: .configuring
        case .previewing: .previewing
        case .recording: .recording
        case .processing: .processing
        case .error: .error
        }
    }

    /// The associated error when in `.error`, otherwise `nil`.
    public var associatedError: CameraError? {
        if case .error(let error) = self { error } else { nil }
    }

    public var isRecording: Bool { phase == .recording }
    public var isActive: Bool { phase != .idle && phase != .error }

    public var description: String {
        switch self {
        case .error(let error): "error(\(error))"
        default: phase.rawValue
        }
    }
}

// MARK: - Camera position

/// Physical camera used for capture.
public nonisolated enum CameraPosition: String, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    /// Primary wide-angle back camera (1x).
    case back
    /// Front TrueDepth camera (self-tapes).
    case front

    public var description: String { rawValue }

    /// The opposite position.
    public var flipped: CameraPosition {
        switch self {
        case .back: .front
        case .front: .back
        }
    }
}

// MARK: - Transition rules

public nonisolated extension CameraState {
    /// The allowed phase transitions. The state machine rejects everything else.
    static let validTransitions: [CameraPhase: Set<CameraPhase>] = [
        .idle: [.configuring],
        .configuring: [.previewing, .idle, .error],
        .previewing: [.recording, .configuring, .idle, .error],
        .recording: [.processing, .error],
        .processing: [.previewing, .idle, .error],
        .error: [.idle, .configuring],
    ]

    /// Whether moving from `self` to `next` is legal.
    func allowsTransition(to next: CameraState) -> Bool {
        guard let allowed = Self.validTransitions[phase] else { return false }
        return allowed.contains(next.phase)
    }
}

// MARK: - Errors

/// Errors surfaced by the capture pipeline. `Sendable` + `Equatable` so errors
/// can cross concurrency domains and be compared in tests.
public nonisolated enum CameraError: Error, Sendable, Equatable {
    case permissionDenied
    case configurationFailed(reason: String)
    case sessionInterrupted(reason: String)
    case invalidStateTransition(from: CameraPhase, to: CameraPhase)
    case writerFailed(reason: String)
    case renderFailed(reason: String)
    case unknown(reason: String)
}
