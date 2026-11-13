// Pareto for Mac. Runs as a menu bar app, or runs its self-test from Terminal
// (see SelfTest.swift).

import AppKit

Fonts.register()
let arguments = CommandLine.arguments
let testing = ["--selftest", "--nemotron", "--route", "--pdf", "--ocr", "--screen", "--render", "--icon"].contains { arguments.contains($0) }

if testing {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await SelfTest.run(arguments)
            exit(SelfTest.failures == 0 ? 0 : 1)
        }
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
