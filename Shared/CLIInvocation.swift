import Foundation

/// How `keepy-uppy` is invoked, and the one thing a link on your `PATH` cannot
/// buy you.
///
/// In `Shared/` because the two sides have to agree: the app tells you how to
/// run the CLI (the Settings pane, `Sources/SessionDisplay.swift`) and the CLI
/// tells you the same thing when it refuses (`CLI/main.swift`). Two files
/// spelling one command is two places to get the quoting wrong.
///
/// **It grants no capability.** `Shared/` compiles into the root
/// `KeepyUppyHelper`, which has zero exec and zero network capability today and
/// should gain none even unreached — the boundary
/// `Agent/SessionCompletionNotifier.swift` is on the far side of. Nothing here
/// launches, opens or connects to anything: it is string construction and a
/// `stat`-shaped predicate whose filesystem access is injected by the caller.
/// A command string is a thing a human pastes into a shell, not a thing this
/// process runs.

// MARK: - Quoting

/// A path as a single shell word, for any path.
///
/// Single quotes, with an embedded single quote closed, escaped and reopened —
/// the `'\''` idiom. This is *total*: inside single quotes a shell interprets
/// nothing at all, so a space, a `$`, a backtick, a `"`, a newline and a `\`
/// all survive verbatim, and the one character that would end the quoting is
/// the one handled explicitly.
///
/// The current bundle name contains a space (`/Applications/Keepy Uppy.app`),
/// which is what makes this load-bearing rather than defensive: unquoted, the
/// `ln -s` below installs a link named `Keepy` pointing at nothing, or fails
/// in a way the user cannot read.
///
/// Double quotes were the obvious alternative and are not enough — `$` and a
/// backtick both survive them and both are legal in a macOS file name.
func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A path as a single **double-quoted** shell word.
///
/// Needed for exactly one place, and it is a place single quotes cannot go: the
/// `ssh host '…'` form, where the outer single quotes belong to the local shell
/// and the remote shell needs quoting of its own. Nesting single quotes inside
/// single quotes is not possible without ending them.
///
/// Escapes the four characters a double-quoted shell word still interprets —
/// `\`, `"`, `$` and a backtick — leaving everything else, including the space
/// this exists for, untouched.
func shellDoubleQuoted(_ value: String) -> String {
    var escaped = ""
    for character in value {
        if character == "\\" || character == "\"" || character == "$" || character == "`" {
            escaped.append("\\")
        }
        escaped.append(character)
    }
    return "\"" + escaped + "\""
}

// MARK: - The bundle a symlinked CLI loses

/// Why `keepy-uppy setup` and `keepy-uppy reset` refuse to run through a link
/// on your `PATH`.
///
/// ## The measurement
///
/// **`Bundle.main` does not follow a symlink.** Measured with a throwaway probe
/// built in the exact shape of this CLI target — a Swift `tool` with an embedded
/// `__TEXT,__info_plist` section, living in `Contents/MacOS/` — invoked once
/// directly and once through a symlink in a directory standing in for
/// `/usr/local/bin` (`.superpowers/sdd/plan7-path-symlink-research.md` §1.4,
/// Hazard C):
///
///     (a) at its real path      bundlePath: …/Fake App.app
///     (b) through the symlink   bundlePath: …/fakebin      ← the link's directory
///
/// `_NSGetExecutablePath` returns the path **as invoked**, CFBundle walks up
/// from that, and the `.app` is simply not on that path any more.
/// `bundleIdentifier` **survives** either way, because it comes from the
/// embedded section — so the process still looks like it has an identity, and
/// only the bundle is gone. That is what makes the failure quiet.
///
/// ## Why it matters here and nowhere else
///
/// `SMAppService.daemon(plistName:)` and `.agent(plistName:)` look for their
/// plists in **the calling app's own bundle** — `SMAppService.h:121`, "the
/// plistName must correspond to a plist in the calling app's
/// Contents/Library/LaunchDaemons directory" — and the class has no constructor
/// that takes a bundle, a URL or a path. All three of its constructors were
/// enumerated; the recovery function that finds the real `.app` from the
/// resolved executable path works and has **nowhere to hand its answer**. So the
/// obvious fix does not exist, and this refusal is the fix.
///
/// `setup` and `reset` are the only two verbs that call it. `on`, `off`,
/// `status`, `sessions` and `finished` are pure XPC plus `UserDefaults` and work
/// perfectly through the link — over-restricting them would break the feature
/// this refusal exists to make safe.
///
/// ## Why refusing is not merely tidy
///
/// `setup` through the link already failed loudly: the throw is caught, stderr
/// gets a line, the exit code is 1. **`reset` is the dangerous one.**
/// `unregisterAndReport` catches the same throw and, when `service.status` is
/// `.notRegistered` or `.notFound` — which a missing plist plausibly produces —
/// prints **"Daemon: not registered"** and leaves the exit code at 0. A clean
/// uninstall report, while the daemon is still fully registered and still
/// holding this Mac awake. That is this project's signature failure mode, on
/// the one operation whose ordering rule was itself the subject of a whole
/// review cycle.
enum CLIBundleGuard {
    /// The verb name when this command needs to be able to see its own `.app`,
    /// `nil` when it does not.
    ///
    /// Exhaustive, so a new verb has to decide rather than inheriting whichever
    /// answer was cheaper to write. One function rather than a predicate plus a
    /// name, because two switches over the same enum drift.
    static func appBundleVerb(_ command: CLICommand) -> String? {
        switch command {
        case .setup: return "setup"
        case .reset: return "reset"
        case .on, .off, .status, .sessions, .finished: return nil
        }
    }

    /// Where `SMAppService` will look for the daemon's job description.
    static func daemonPlistPath(inBundle bundlePath: String) -> String {
        bundlePath + "/Contents/Library/LaunchDaemons/" + helperPlistName
    }

    /// Where `SMAppService` will look for the agent's.
    static func agentPlistPath(inBundle bundlePath: String) -> String {
        bundlePath + "/Contents/Library/LaunchAgents/" + agentPlistName
    }

    /// Whether `bundlePath` is a real app bundle carrying both job descriptions.
    ///
    /// It checks **the actual precondition**, not a proxy for it. "Ends in
    /// `.app`" alone would pass for a directory called `x.app` with nothing in
    /// it; asking whether the two plists are where `SMAppService` will look for
    /// them is the same question `SMAppService` is about to ask, which is the
    /// only version of it that cannot drift.
    ///
    /// - Parameter exists: injected so this stays pure and testable. The CLI
    ///   passes `FileManager.default.fileExists(atPath:)`.
    static func isUsableAppBundle(_ bundlePath: String, exists: (String) -> Bool) -> Bool {
        guard (bundlePath as NSString).pathExtension == "app" else { return false }
        return exists(daemonPlistPath(inBundle: bundlePath))
            && exists(agentPlistPath(inBundle: bundlePath))
    }

    /// The `.app` enclosing a **resolved** executable path, or `nil`.
    ///
    /// Pure string work on a path whose symlinks the caller has already
    /// resolved — the resolution is the impure half and lives in
    /// `resolvedExecutablePath()` below. This is what lets the refusal name the
    /// command that *will* work rather than pointing at a document.
    static func enclosingAppBundle(ofResolvedExecutable path: String) -> String? {
        var components = (path as NSString).pathComponents
        while let last = components.last {
            if (last as NSString).pathExtension == "app" {
                return NSString.path(withComponents: components)
            }
            components.removeLast()
        }
        return nil
    }

    /// The refusal message, or `nil` when this process can see its bundle and
    /// the verb may proceed.
    ///
    /// - Parameter resolvedExecutablePath: this process's executable with every
    ///   symlink resolved. Used *only* to name a command that will work; the
    ///   decision itself is made on `bundlePath` alone, because that is the
    ///   thing `SMAppService` will actually consult.
    static func refusal(verb: String,
                        bundlePath: String,
                        resolvedExecutablePath: String,
                        exists: (String) -> Bool) -> String? {
        guard !isUsableAppBundle(bundlePath, exists: exists) else { return nil }

        let explanation = "'\(verb)' has to run from inside Keepy Uppy.app, and this copy cannot see one."
            + " macOS resolves a program's bundle from the path it was started at, so a link on your PATH"
            + " leaves the app bundle — and the launchd job descriptions inside it — out of reach."
            + " Refusing here rather than reporting a result that would be a guess."

        guard let bundle = enclosingAppBundle(ofResolvedExecutable: resolvedExecutablePath),
              isUsableAppBundle(bundle, exists: exists) else {
            // Nothing to point at: this really is a loose copy of the binary
            // rather than a link into a bundle. Name the shape of the answer
            // instead of a path that may not exist.
            return explanation
                + " Run it with the full path to keepy-uppy inside Keepy Uppy.app instead —"
                + " \(shellSingleQuoted("/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy")) \(verb)"
        }
        return explanation
            + " Run this instead: \(shellSingleQuoted(resolvedExecutablePath)) \(verb)"
    }

    /// This process's own executable, as invoked, with every symlink resolved.
    ///
    /// The impure half, kept to four lines and out of everything above.
    /// `_NSGetExecutablePath` rather than `CommandLine.arguments[0]`: a shell
    /// that found this program on the `PATH` sets `argv[0]` to the bare word the
    /// user typed, which is not a path at all.
    static func resolvedExecutablePath() -> String {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "" }
        let asInvoked = String(cString: buffer)
        guard let real = realpath(asInvoked, nil) else { return asInvoked }
        defer { free(real) }
        return String(cString: real)
    }
}
