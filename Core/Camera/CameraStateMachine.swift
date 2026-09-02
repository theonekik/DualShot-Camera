//
//  CameraStateMachine.swift
//  DualShot Camera
//
//  A thread-safe, globally accessible state machine — the single source of
//  truth for the capture pipeline's state. Every layer (engine, writer, UI)
//  reads from here and transitions through here.
//

import Foundation
import Synchronization

/// Thread-safe state machine over `CameraState`.
///
/// ## Thread safety
/// All state is guarded by a `Synchronization.Mutex`; validated reads and
/// writes can happen from any thread. The type itself is `Sendable` because
/// every stored property is `Sendable` (mutex, stream, continuation).
///
/// ## Global access
/// `CameraStateMachine.shared` is the app-wide instance used by the engine,
/// the writer, and the UI-facing `CameraSessionModel`.
///
/// ## Notification
/// Every accepted transition is forwarded to the `states` stream — a unicast
/// `AsyncStream`. `CameraSessionModel` owns the single subscription; other
/// components should poll `state` (or `phase`) instead of iterating.
public nonisolated final class CameraStateMachine: Sendable {

    /// App-wide instance.
    public static let shared = CameraStateMachine()

    private let lock: Mutex<CameraState>
    private let statesStream: AsyncStream<CameraState>
    private let statesContinuation: AsyncStream<CameraState>.Continuation

    public init(initialState: CameraState = .idle) {
        lock = Mutex(initialState)
        let (stream, continuation) = AsyncStream<CameraState>.makeStream(bufferingPolicy: .unbounded)
        statesStream = stream
        statesContinuation = continuation
    }

    /// Current state. Safe to call from any thread.
    public var state: CameraState {
        lock.withLock { $0 }
    }

    /// Current phase. Safe to call from any thread.
    public var phase: CameraPhase {
        state.phase
    }

    /// Unicast stream of every accepted transition. Subscribe exactly once.
    public var states: AsyncStream<CameraState> {
        statesStream
    }

    /// Validates and applies a transition.
    ///
    /// - Throws: `CameraError.invalidStateTransition` when the transition is
    ///   not allowed by `CameraState.validTransitions`.
    ///
    /// The new state is yielded to `states` only after the mutation commits.
    /// The yield happens outside the lock so a consumer can never re-enter
    /// `transition` on the same thread (Mutex is not recursive); in practice
    /// the engine serializes all transitions, so ordering is preserved.
    @discardableResult
    public func transition(to newState: CameraState) throws -> CameraState {
        let result = lock.withLock { current -> Result<CameraState, CameraError> in
            guard current.allowsTransition(to: newState) else {
                return .failure(.invalidStateTransition(from: current.phase, to: newState.phase))
            }
            current = newState
            return .success(newState)
        }
        switch result {
        case .success(let state):
            statesContinuation.yield(state)
            return state
        case .failure(let error):
            throw error
        }
    }

    /// Applies a transition without validation — reserved for error-recovery
    /// paths (e.g. forced teardown from any state).
    @discardableResult
    public func forceTransition(to newState: CameraState) -> CameraState {
        lock.withLock { $0 = newState }
        statesContinuation.yield(newState)
        return newState
    }

    /// Stops the notification stream; further transitions are not observable.
    public func close() {
        statesContinuation.finish()
    }
}
