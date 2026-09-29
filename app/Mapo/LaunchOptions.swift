import Foundation

/// The app's command line (PLAN T0.7 step 1): `--instance NAME` (or `--instance=NAME`) and
/// `--no-spawn-daemon`. Anything else, such as the `-NS…` pairs Xcode passes, is ignored.
struct LaunchOptions {
    var instance: String?
    var spawnDaemon = true

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--instance", index + 1 < arguments.count {
                instance = arguments[index + 1]
                index += 1
            } else if argument.hasPrefix("--instance=") {
                instance = String(argument.dropFirst("--instance=".count))
            } else if argument == "--no-spawn-daemon" {
                spawnDaemon = false
            }
            index += 1
        }
    }
}
