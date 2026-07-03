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
        // Keep the window from shrinking smaller than its content needs,
        // so panes can't be cut off.
        .windowResizability(.contentMinSize)
    }
}
