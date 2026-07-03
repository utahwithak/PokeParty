//
//  View+Platform.swift
//  PokeParty
//
//  Small cross-platform shims for iOS-only view modifiers.
//

import SwiftUI

extension View {
    /// Applies the inline navigation bar title display mode on platforms that
    /// support it (iOS); a no-op elsewhere (e.g. macOS).
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
