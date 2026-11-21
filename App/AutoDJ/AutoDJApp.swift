// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import AppKit
import AutoDJKit
import SwiftUI

@main
struct AutoDJApp: App {
    @State private var app = AppModel()
    @State private var player = Player()

    var body: some Scene {
        WindowGroup("auto-dj") {
            ContentView(renderer: SetRenderer(cacheDir: app.paths.renderDir))
                .environment(app)
                .environment(player)
                .frame(minWidth: 1100, minHeight: 680)
                .task { await app.refresh() }
        }
        Settings {
            SettingsView().environment(app)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case library = "Library"
    case cues = "Cue plan"
    case evaluate = "Evaluate"
    case sets = "Sets"
    case histories = "Histories"
    case demo = "Demo"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .library: "books.vertical"
        case .cues: "flag"
        case .evaluate: "checkmark.seal"
        case .sets: "music.note.list"
        case .histories: "clock.arrow.circlepath"
        case .demo: "wand.and.stars"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var section: SidebarItem? = .sets
    /// The open set, kept while other sections are shown.
    @State private var sets = SetsState()
    @State private var cuePlan = CuePlanState()
    @State private var histories = HistoriesState()
    let renderer: SetRenderer

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
                .navigationSplitViewColumnWidth(min: 160, ideal: 180)
            Spacer()
            RekordboxBadge().font(.caption).padding(8)
        } detail: {
            switch section ?? .sets {
            case .library: LibraryView()
            case .cues: CuePlanView(state: cuePlan)
            case .evaluate: EvaluateView()
            case .sets: SetsView(state: sets, renderer: renderer)
            case .histories: HistoriesView(state: histories)
            case .demo: DemoView(renderer: renderer)
            }
        }
        .alert(
            "Something went wrong", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })
        ) {
            Button("OK") { app.error = nil }
        } message: {
            Text(app.error ?? "")
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            TextField("Rekordbox folder", text: $app.rbDir).help("Holds master.db and share/")
            TextField("Work folder", text: $app.workDir).help("Feature cache, plans and the render cache")
            Text("Use a copied library folder to try writes safely.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 520)
        .onChange(of: app.rbDir) { Task { await app.refresh() } }
    }
}
