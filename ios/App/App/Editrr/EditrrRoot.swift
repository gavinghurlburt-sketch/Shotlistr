import SwiftUI

// Kept out of CreatrrHome.swift on purpose: that file imports Capacitor, whose own type named
// KeyPath hides Swift's, and @Observable's generated code needs Swift's.

/// What editrr's back button says; changes when your plan does.
@MainActor @Observable
final class CreatrrNav {
    var backTitle = "Artist"
}

/// editrr inside creatrr: dark, creatrr's yellow, with a way back to the artist page.
struct EditrrRoot: View {
    let nav: CreatrrNav
    let back: () -> Void

    var body: some View {
        EditorView()
            .environment(\.creatrrBack, back)
            .environment(\.creatrrBackTitle, nav.backTitle)
            .environment(\.colorScheme, .dark)
            .tint(Tint.accent)
    }
}
