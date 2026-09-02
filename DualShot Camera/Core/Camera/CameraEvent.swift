//
//  CameraEvent.swift
//  DualShot Camera
//
//  App-facing domain events emitted by the engine and forwarded by
//  `CameraSessionModel` to its event stream.
//

import Foundation

/// High-level events the app layer cares about (recording lifecycle, errors,
/// preset changes). These complement the state machine: state answers "what
/// phase am I in?", events answer "what just happened?".
public nonisolated enum CameraEvent: Sendable, Equatable {
    /// A new preset was applied to the session.
    case presetApplied(QualityPreset)
    /// The active physical camera changed.
    case cameraSwitched(CameraPosition)
    /// Cinematic Mode active state changed (`true` = depth blur is rendering).
    case cinematicChanged(Bool)
    /// Cinematic Mode was activated, but the capture format was automatically
    /// switched to a depth-capable one (e.g. 4K/60 fps → 1080p@30); `message`
    /// is the user-facing toast text.
    case cinematicAdjusted(String)
    /// Cinematic Mode is armed but waiting on the system Portrait Effect toggle
    /// (Control Center); `message` guides the user. The engine activates
    /// automatically once the toggle is enabled.
    case cinematicPending(String)
    /// Cinematic Mode could not be activated; `message` explains why.
    case cinematicUnsupported(String)
    /// A dual recording session was opened (both writers started).
    case recordingStarted(DualRecordingSession)
    /// Both writers finished; `result` holds the two output files.
    case recordingFinished(DualRecordingResult)
    /// The in-flight recording was aborted.
    case recordingCancelled
    /// The pipeline reported a recoverable error.
    case errorOccurred(CameraError)
}
