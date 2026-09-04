//
//  ContentView.swift
//  DualShot Camera
//
//  Root view: hosts the dual-camera screen and drives the session lifecycle
//  (permissions → configure → live preview). Pure UI — all capture logic lives
//  behind the @Observable `CameraSessionModel`.
//

import SwiftUI

struct ContentView: View {

    @Environment(CameraSessionModel.self) private var model

    var body: some View {
        CameraScreen()
            .task {
                do {
                    try await model.start()
                } catch {
                    // Failures surface through `state == .error` / the banner.
                    model.reportError(error)
                }
            }
    }
}
