import Foundation

/// Putting `keepy-uppy` on the user's `PATH`, and — more of the time — telling
/// them exactly how to do it themselves.
///
/// `Sources/`, not `Shared/`: the daemon and the CLI have no business knowing
/// how the CLI gets onto a `PATH`. What *is* in `Shared/` is
/// `Shared/CLIInvocation.swift`, which both sides need — the shell quoting, and
/// the guard that stops `setup`/`reset` from lying when they are run through the
/// link this file creates.
///
/// ## Why there is a fallback at all
///
/// `/usr/local/bin` is `root:wheel drwxr-xr-x` on a stock Mac, and `/usr/local`
/// is too — so an unprivileged process can neither write into it nor create it.
/// Measured, on this machine, in `.superpowers/sdd/plan7-path-symlink-research.md`
/// §1.1. It is nonetheless the target, because it is the only directory on the
/// **default** `PATH` (`/etc/paths`, §1.2) — `/opt/homebrew/bin` is Homebrew's
/// namespace and does not exist on an Intel Mac or on a Mac without Homebrew,
/// and a user-owned directory only works if the app also edits the user's shell
/// startup files, which this app does not do.
///
/// So the unprivileged `symlink()` is **attempted** — it succeeds on a machine
/// whose `/usr/local` has been chowned, which is a real if uncommon shape — and
/// its failure produces the one-line `sudo` command the user runs themselves.
/// No privileged route was invented: not `AuthorizationExecuteWithPrivileges`
/// (deprecated, and "run this arbitrary thing as root" is not a trade worth
/// making for one symlink), and above all not a filesystem-write verb in the
/// root daemon, which today has no write capability at all and should gain none.
/// The whole argument is Step 2 of that research document.
///
/// ## Why it attempts rather than predicts
///
/// There is no `access(W_OK)` preflight anywhere below. Two reasons, and the
/// second is the one this project keeps relearning: `access()` is a TOCTOU by
/// construction, and `access()` answering "no" is a *prediction* of failure
/// while `symlink()` returning `-1` **is** the failure. The recurring bug here
/// is trusting a call that reports success while doing nothing; the mirror
/// image is trusting a call that reports failure without having tried.
///
/// For the same reason `install()` and `remove()` do not believe their own
/// return values. Both re-read the filesystem afterwards and report what is
/// actually there — "the API returned success" has been accepted as evidence
/// three times in this project and has been wrong three times.

// MARK: - The seam

/// What `lstat(2)` sees at a path: a symlink (with its raw target), or
/// something that is not a symlink.
///
/// `lstat`, never `stat`, is the whole point of the distinction — a dangling
/// symlink must be *seen* rather than resolved away into "nothing is there",
/// because "nothing is there" is the one state that invites a write.
enum CLIPathEntry: Equatable {
    case symlink(target: String)
    /// A regular file, a directory, a socket — anything else. Undifferentiated
    /// on purpose: this app will not touch any of them, so telling them apart
    /// would be a distinction with no consequence.
    case other
}

/// The filesystem, behind a seam of the shape `PowerAssertionBackend`
/// established and `SleepSettingBackend` repeated.
///
/// It exists so a unit test can exercise every branch — including the ones that
/// create and remove links — **without a test ever being able to touch
/// `/usr/local/bin`**. That is structural rather than a matter of care: the fake
/// has no way to reach the real filesystem at all, and every `CLIInstallation`
/// a test builds is handed an explicit directory.
///
/// **No member has a default implementation**, per `ObserverSet`'s rule: a new
/// member must be a compile error at every conformance rather than a silent
/// substitution of somebody else's idea of harmless.
protocol CLIInstallFileSystem {
    /// `lstat`. `nil` when nothing is at `path`.
    func entry(at path: String) -> CLIPathEntry?
    /// `stat` — i.e. following a final symlink. `false` for a dangling link.
    func exists(following path: String) -> Bool
    /// `realpath`. Returns `path` unchanged when it cannot be resolved, so a
    /// caller never has to handle a second kind of nothing.
    ///
    /// Both sides of the "is this link ours?" comparison go through this:
    /// `/tmp` vs `/private/tmp`, `/var` vs `/private/var` and a relocated `.app`
    /// all produce two spellings of one path, and comparing spellings would
    /// report a link as somebody else's on the strength of a symlinked prefix.
    func canonical(_ path: String) -> String
    /// `mkdir -p`. Best-effort: its failure is not the answer, the `symlink`
    /// that follows is.
    func createDirectory(at path: String) throws
    /// `symlink(2)`. Throws on failure — which is the ordinary case here, and
    /// is what produces the `sudo` command rather than an error.
    func createSymbolicLink(at path: String, to target: String) throws
    /// `unlink(2)`.
    func removeItem(at path: String) throws
}

struct FileManagerCLIInstallFileSystem: CLIInstallFileSystem {
    func entry(at path: String) -> CLIPathEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFLNK else { return .other }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            // `lstat` said symlink and `readlink` disagreed, which means the
            // path changed underneath us. Reporting `.other` is the direction
            // that refuses to write.
            return .other
        }
        return .symlink(target: target)
    }

    func exists(following path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    func createSymbolicLink(at path: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
    }

    func removeItem(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

// MARK: - Where it goes

/// The install location, named once.
///
/// **There is no preference for this and there must not be one.** The state is
/// the filesystem; a copy of it in `UserDefaults` would be a second source of
/// truth that goes stale the moment the user moves the app, and the stale copy
/// is the one the pane would show.
enum CLIInstallPaths {
    /// First entry in `/etc/paths`, so it is on the default `PATH` of every
    /// user of every Mac with no Homebrew and no dotfile involved.
    static let defaultDirectory = "/usr/local/bin"

    /// What the user types. Also the link's own filename.
    static let linkName = "keepy-uppy"

    /// The directory to install into.
    ///
    /// The override is a **launch environment variable, read only in a Debug
    /// build**, and deliberately not a `UserDefaults` key. `PreferencesSuite`
    /// redirects only under XCTest: outside it, that domain is the user's
    /// production one and the installed Release app reads it live — so a
    /// temporary default written to test this would point the *shipping* app's
    /// installer at a scratch directory, and would survive the process that
    /// wrote it. An environment variable dies with the process it was set on
    /// and cannot be seen by any other build.
    static var directory: String {
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["KEEPY_UPPY_CLI_INSTALL_DIR"]
        if let override, !override.isEmpty { return override }
        #endif
        return defaultDirectory
    }
}

// MARK: - What is there

/// What is at the install path right now — five states, each a different
/// sentence and a different button.
///
/// Hazard B from the research: a symlink may already be there pointing
/// somewhere else, and that is a thing to **report, never to overwrite
/// silently**. Somebody else's `keepy-uppy` — a second copy of the app, a
/// Homebrew build, a hand-rolled wrapper — is not this app's to replace.
enum CLIInstallState: Equatable {
    /// Nothing at the path. The only state in which this app writes anything.
    case notInstalled

    /// A symlink that resolves into *this* bundle. The happy idempotent case.
    ///
    /// "Resolves into this bundle" is the claim, and it is stronger than "is a
    /// symlink to some `keepy-uppy`": a link to a *different* copy of the app
    /// would let the pane say "Installed" about a binary this app is not.
    case installed

    /// A symlink to something that exists and is not this bundle's binary.
    case linkedElsewhere(target: String)

    /// A symlink whose target does not exist — usually a previous install whose
    /// app was moved or deleted, or a volume that is not mounted. "Installed"
    /// would be a lie, and so would "nothing is there".
    case dangling(target: String)

    /// Something that is not a symlink at all. Never touched: a regular file at
    /// that name is another product's, or the user's.
    case occupied
}

// MARK: - What happened

enum CLIInstallResult: Equatable {
    /// Created **and read back** from the filesystem as ours.
    case installed
    /// Already ours. Nothing was written.
    case alreadyInstalled
    /// The unprivileged attempt was refused. This is the ordinary outcome on a
    /// stock Mac, and the command is the whole answer to it.
    case needsPrivilege(command: String)
    /// Something is at the path that this app will not touch.
    case blocked(CLIInstallState)
    /// The link was created and did not read back as ours.
    ///
    /// Should be unreachable. It exists so that "the call returned without
    /// throwing" can never be the thing this function reports.
    case createdButNotVerified(CLIInstallState)
}

enum CLIRemoveResult: Equatable {
    /// Removed, **and read back** as gone.
    case removed
    /// Nothing was there.
    case nothingToRemove
    /// The unprivileged `unlink` was refused. `/usr/local/bin` is root-owned, so
    /// this is as ordinary as its counterpart above.
    case needsPrivilege(command: String)
    /// Not provably this app's link. Removal is only ever safe for one that is.
    case refused(CLIInstallState)
    /// `unlink` returned and something is still there.
    case removedButStillThere(CLIInstallState)
}

// MARK: - The operations

/// The pure part: what is at the path, what a click will attempt, and what to
/// say when the attempt is refused.
///
/// Every path it touches is passed in. There is no default construction site in
/// this type at all — `forThisApp()` is the one place `/usr/local/bin` and
/// `Bundle.main` meet, and it is called by the Settings pane and by nothing
/// else. That is what keeps a test structurally unable to reach the real
/// directory.
struct CLIInstallation {
    let fileSystem: CLIInstallFileSystem
    /// The directory the link goes in — `/usr/local/bin` in the app.
    let directory: String
    /// The `keepy-uppy` inside this app bundle, which the link must point at.
    let binaryPath: String

    /// The link itself.
    var linkPath: String { directory + "/" + CLIInstallPaths.linkName }

    /// The app's one construction site.
    ///
    /// `Bundle.main.bundlePath` rather than a literal `/Applications`: a user
    /// running from `~/Downloads` or from a build directory must get a link —
    /// and a `sudo` command — that points at *their* copy, or the link points
    /// at a bundle that is not the one that made it.
    static func forThisApp() -> CLIInstallation {
        CLIInstallation(
            fileSystem: FileManagerCLIInstallFileSystem(),
            directory: CLIInstallPaths.directory,
            binaryPath: Bundle.main.bundlePath + "/Contents/MacOS/" + CLIInstallPaths.linkName)
    }

    func state() -> CLIInstallState {
        guard let entry = fileSystem.entry(at: linkPath) else { return .notInstalled }
        guard case .symlink(let target) = entry else { return .occupied }
        guard fileSystem.exists(following: linkPath) else { return .dangling(target: target) }
        // Both sides resolved, and the *link* resolved rather than its raw
        // target joined by hand — a relative target ("../Foo.app/…") is a
        // perfectly ordinary symlink and joining it here would be a second,
        // worse implementation of `realpath`.
        return fileSystem.canonical(linkPath) == fileSystem.canonical(binaryPath)
            ? .installed
            : .linkedElsewhere(target: target)
    }

    /// Attempts the unprivileged link, and answers with the `sudo` command when
    /// that is refused. Never overwrites anything.
    func install() -> CLIInstallResult {
        let before = state()
        switch before {
        case .installed:
            return .alreadyInstalled
        case .linkedElsewhere, .dangling, .occupied:
            return .blocked(before)
        case .notInstalled:
            break
        }

        // Best-effort, and its failure is deliberately not reported: on a stock
        // Mac `/usr/local` is not user-writable either, so this fails and the
        // `symlink` below fails with `ENOENT` — which lands in exactly the same
        // place as `EACCES` and produces the same command, whose own `mkdir -p`
        // is there for precisely this case.
        try? fileSystem.createDirectory(at: directory)

        do {
            try fileSystem.createSymbolicLink(at: linkPath, to: binaryPath)
        } catch {
            return .needsPrivilege(command: cliInstallCommand(binaryPath: binaryPath,
                                                              linkPath: linkPath))
        }

        let after = state()
        guard after == .installed else { return .createdButNotVerified(after) }
        return .installed
    }

    /// Removes the link — **only** when it provably resolves into this bundle.
    ///
    /// A dangling link is deliberately not removable here even though it is
    /// probably a previous install of this very app: "probably ours" is not
    /// "ours", and one rule ("this app only ever removes a link it can prove
    /// points at its own binary") is worth more than the convenience. The
    /// command for that case is offered instead.
    func remove() -> CLIRemoveResult {
        let before = state()
        switch before {
        case .notInstalled:
            return .nothingToRemove
        case .linkedElsewhere, .dangling, .occupied:
            return .refused(before)
        case .installed:
            break
        }

        do {
            try fileSystem.removeItem(at: linkPath)
        } catch {
            return .needsPrivilege(command: cliRemoveCommand(linkPath: linkPath))
        }

        let after = state()
        guard after == .notInstalled else { return .removedButStillThere(after) }
        return .removed
    }

    /// The command to hand the user for the state they are in *before* they
    /// have clicked anything, or `nil` when there is nothing to offer yet.
    ///
    /// The two states with a button (`.notInstalled`, `.installed`) get their
    /// command from the *result* of clicking it, not from here — a `sudo rm`
    /// sitting permanently under the word "Installed" is a command nobody asked
    /// for, next to a button that has not been refused yet.
    ///
    /// It is `nil` for `.linkedElsewhere` and `.occupied` on purpose. Handing
    /// over an `ln -sfh` there would be handing over a command that clobbers the
    /// very thing the sentence beside it has just said not to clobber — and
    /// unlike the app, the user pasting it into a root shell would succeed.
    /// Somebody who genuinely wants to replace another product's binary does not
    /// need this app to write the command for them.
    func fallbackCommand(for state: CLIInstallState) -> String? {
        switch state {
        case .dangling:
            // `-f`, because a plain `ln -s` fails loudly when something is
            // already at the path — which is correct for the install command and
            // useless for this one. `-h` with it, because `ln -sf` onto a
            // symlink that points at a *directory* creates the link **inside**
            // that directory instead of replacing it.
            return cliReplaceCommand(binaryPath: binaryPath, linkPath: linkPath)
        case .notInstalled, .installed, .linkedElsewhere, .occupied:
            return nil
        }
    }
}
