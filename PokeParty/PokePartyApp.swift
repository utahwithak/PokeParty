//
//  PokePartyApp.swift
//  PokeParty
//
//  Created by Carl Wieland on 6/29/26.
//

import SwiftUI

@main
struct PokePartyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Opening a .pokeparty file should reuse this window (and its stores)
        // rather than spawn a new one.
        .handlesExternalEvents(matching: ["*"])
        // Keep the window from shrinking smaller than its content needs,
        // so panes can't be cut off.
        .windowResizability(.contentMinSize)
    }
}
