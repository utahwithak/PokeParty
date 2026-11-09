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

    /// Grows a small icon button's hit area to a touch-friendly size on iOS
    /// (Apple's minimum is 44pt) without changing how it looks; a no-op on macOS.
    func touchTarget(width: CGFloat = 44, height: CGFloat = 44) -> some View {
        #if os(iOS)
        frame(minWidth: width, minHeight: height)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }

    /// Applies the checkbox toggle style on platforms that support it (macOS);
    /// the default style elsewhere (e.g. iOS).
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
