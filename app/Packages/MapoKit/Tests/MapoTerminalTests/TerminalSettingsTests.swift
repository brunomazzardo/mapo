import Foundation
import Testing

@testable import MapoTerminal

@Test func defaultsWithoutTerminalTable() {
    let settings = TerminalSettings(configTOML: "[ui]\ntheme = \"mapo-glass\"\n")
    #expect(settings == TerminalSettings())
    #expect(settings.engine == .swiftterm)
}

@Test func readsTerminalTable() {
    let toml = """
        # Mapo config
        [shell]
        font-size = 30

        [terminal]  # the terminal
        engine = "ghostty"
        font-family = 'JetBrains Mono'   # quoted with single quotes
        "font-size" = 14
        option-as-alt = true
        scrollback-lines = 10_000

        [agent]
        engine = "swiftterm"
        """
    let settings = TerminalSettings(configTOML: toml)
    #expect(settings.engine == .ghostty)
    #expect(settings.fontFamily == "JetBrains Mono")
    #expect(settings.fontSize == 14)
    #expect(settings.optionAsAlt)
}

@Test func keepsDefaultsForBadValues() {
    let toml = """
        [terminal]
        engine = "kitty"
        font-size = "big"
        option-as-alt = 1
        font-family = ""
        """
    #expect(TerminalSettings(configTOML: toml) == TerminalSettings())
}

@Test func attachLaunchStripsTabCredentials() {
    let launch = TerminalLaunch.attach(
        helper: URL(filePath: "/A/Mapo.app/Contents/Helpers/mapo"), tabId: "t1", instance: "dev-x")
    #expect(launch.executable == "/A/Mapo.app/Contents/Helpers/mapo")
    #expect(launch.arguments == ["attach", "--tab", "t1", "--instance", "dev-x"])
    let env = launch.resolvedEnvironment(base: [
        "HOME": "/Users/u", "MAPO_TOKEN": "secret", "MAPO_HOOK_TOKEN": "h", "MAPO_INSTANCE": "main", "TERM": "dumb",
    ])
    #expect(env == ["HOME=/Users/u", "LANG=en_US.UTF-8", "MAPO_INSTANCE=dev-x", "TERM=xterm-256color"])
}

@Test func decodesWaitStatus() {
    #expect(SwiftTermSurfaceView.exitCode(fromWaitStatus: 2 << 8) == 2)
    #expect(SwiftTermSurfaceView.exitCode(fromWaitStatus: 0) == 0)
    #expect(SwiftTermSurfaceView.exitCode(fromWaitStatus: 9) == 137)
}
