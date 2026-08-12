import XCTest
@testable import KeepyUppy

// MARK: - The fake

/// A small real filesystem, in memory.
///
/// It mutates: a link created through it is visible to the next `lstat`, and a
/// link removed through it is gone. That matters because `install()` and
/// `remove()` deliberately do not believe their own return values — they read
/// the path back — and a fake that only records calls would let that readback
/// pass without ever having been exercised.
///
/// **No test can reach `/usr/local/bin` through this**, and that is structural
/// rather than a matter of care: it has no path to the real filesystem at all,
/// and every `CLIInstallation` below is handed an explicit directory.
private final class FakeFileSystem: CLIInstallFileSystem {
    /// What `lstat` sees.
    var entries: [String: CLIPathEntry] = [:]
    /// What `stat` sees — i.e. what survives following a final symlink.
    var reachable: Set<String> = []
    /// What `realpath` answers, for paths with more than one spelling.
    var canonicalNames: [String: String] = [:]

    var createSymlinkError: Error?
    var createDirectoryError: Error?
    var removeError: Error?

    /// Returns cleanly and writes nothing — the call that reports success while
    /// doing nothing, which is the thing this project keeps shipping and the
    /// only reason `install()` and `remove()` read the path back at all.
    var createSilentlyDoesNothing = false
    var removeSilentlyDoesNothing = false

    private(set) var symlinksCreated: [(path: String, target: String)] = []
    private(set) var directoriesCreated: [String] = []
    private(set) var removedPaths: [String] = []

    /// Sets up a real file at `path` — something a link can point at.
    func addFile(_ path: String) {
        entries[path] = .other
        reachable.insert(path)
    }

    /// Sets up a symlink, whether or not its target exists.
    func addSymlink(at path: String, to target: String) {
        entries[path] = .symlink(target: target)
        if reachable.contains(target) {
            reachable.insert(path)
            canonicalNames[path] = canonical(target)
        }
    }

    func entry(at path: String) -> CLIPathEntry? { entries[path] }

    func exists(following path: String) -> Bool { reachable.contains(path) }

    func canonical(_ path: String) -> String { canonicalNames[path] ?? path }

    func createDirectory(at path: String) throws {
        if let createDirectoryError { throw createDirectoryError }
        directoriesCreated.append(path)
    }

    func createSymbolicLink(at path: String, to target: String) throws {
        if let createSymlinkError { throw createSymlinkError }
        symlinksCreated.append((path, target))
        guard !createSilentlyDoesNothing else { return }
        addSymlink(at: path, to: target)
    }

    func removeItem(at path: String) throws {
        if let removeError { throw removeError }
        removedPaths.append(path)
        guard !removeSilentlyDoesNothing else { return }
        entries[path] = nil
        reachable.remove(path)
        canonicalNames[path] = nil
    }
}

private let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))

// MARK: - The states, and what each one allows

final class CLIInstallationTests: XCTestCase {
    private let directory = "/usr/local/bin"
    private let link = "/usr/local/bin/keepy-uppy"
    private let binary = "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy"

    private var fileSystem = FakeFileSystem()

    override func setUp() {
        super.setUp()
        fileSystem = FakeFileSystem()
        // This app's own binary is always there — it is the running app.
        fileSystem.addFile(binary)
    }

    private var installation: CLIInstallation {
        CLIInstallation(fileSystem: fileSystem, directory: directory, binaryPath: binary)
    }

    // MARK: Reading the state

    func testNotInstalledWhenNothingIsAtThePath() {
        XCTAssertEqual(installation.state(), .notInstalled)
    }

    func testInstalledWhenTheLinkResolvesIntoThisBundle() {
        fileSystem.addSymlink(at: link, to: binary)
        XCTAssertEqual(installation.state(), .installed)
    }

    /// Two spellings of one path — `/tmp` vs `/private/tmp`, `/var` vs
    /// `/private/var`, a relocated `.app`. Comparing the strings would report
    /// this app's own link as somebody else's on the strength of a symlinked
    /// prefix.
    func testALinkThroughASymlinkedPrefixIsStillOurs() {
        let viaTmp = "/tmp/Keepy Uppy.app/Contents/MacOS/keepy-uppy"
        fileSystem.addFile(viaTmp)
        fileSystem.canonicalNames[viaTmp] = binary
        fileSystem.addSymlink(at: link, to: viaTmp)
        XCTAssertEqual(installation.state(), .installed)
    }

    /// Somebody else's `keepy-uppy` — another copy of the app, a Homebrew
    /// build, a hand-rolled wrapper.
    func testALinkPointingSomewhereElseIsReportedAndNotOverwritten() {
        let theirs = "/opt/homebrew/bin/keepy-uppy"
        fileSystem.addFile(theirs)
        fileSystem.addSymlink(at: link, to: theirs)

        XCTAssertEqual(installation.state(), .linkedElsewhere(target: theirs))
        XCTAssertEqual(installation.install(), .blocked(.linkedElsewhere(target: theirs)))
        XCTAssertEqual(fileSystem.symlinksCreated.count, 0)
        XCTAssertEqual(fileSystem.removedPaths.count, 0)
    }

    func testARegularFileAtThePathIsReportedAndNotOverwritten() {
        fileSystem.addFile(link)

        XCTAssertEqual(installation.state(), .occupied)
        XCTAssertEqual(installation.install(), .blocked(.occupied))
        XCTAssertEqual(fileSystem.symlinksCreated.count, 0)
        XCTAssertEqual(fileSystem.removedPaths.count, 0)
    }

    /// The app was moved, or the volume it lived on was unmounted. "Installed"
    /// would be a lie, and so would "nothing is there" — the second one worse,
    /// because it invites a write that will fail.
    func testADanglingLinkIsNotInstalled() {
        let gone = "/Volumes/Old/Keepy Uppy.app/Contents/MacOS/keepy-uppy"
        fileSystem.addSymlink(at: link, to: gone)

        XCTAssertEqual(installation.state(), .dangling(target: gone))
        XCTAssertEqual(installation.install(), .blocked(.dangling(target: gone)))
        XCTAssertEqual(fileSystem.symlinksCreated.count, 0)
    }

    /// And it is the one occupied state with a command to offer, because the
    /// thing at the other end is already gone.
    func testOnlyADanglingLinkGetsAnUnpromptedCommand() {
        XCTAssertNil(installation.fallbackCommand(for: .notInstalled))
        XCTAssertNil(installation.fallbackCommand(for: .installed))
        XCTAssertNil(installation.fallbackCommand(for: .occupied))
        XCTAssertNil(installation.fallbackCommand(for: .linkedElsewhere(target: "/x")))
        XCTAssertEqual(installation.fallbackCommand(for: .dangling(target: "/x")),
                       cliReplaceCommand(binaryPath: binary, linkPath: link))
    }

    // MARK: Installing

    func testAnUnprivilegedInstallCreatesTheLinkAndReadsItBack() {
        XCTAssertEqual(installation.install(), .installed)
        XCTAssertEqual(fileSystem.symlinksCreated.count, 1)
        XCTAssertEqual(fileSystem.symlinksCreated.first?.path, link)
        XCTAssertEqual(fileSystem.symlinksCreated.first?.target, binary)
        XCTAssertEqual(installation.state(), .installed)
    }

    /// `/usr/local/bin` may be absent, and `/usr/local` is not user-writable
    /// either — so the attempt makes the directory rather than failing on a
    /// machine where it could have succeeded.
    func testItTriesToCreateTheDirectoryBeforeLinkingIntoIt() {
        _ = installation.install()
        XCTAssertEqual(fileSystem.directoriesCreated, [directory])
    }

    /// A refusal must produce the fallback, not a dead end. **This is the
    /// branch nearly every user reaches**: `/usr/local/bin` is
    /// `root:wheel drwxr-xr-x` on any Mac nobody has chowned.
    func testAPermissionFailureProducesTheSudoCommandRatherThanAnError() {
        fileSystem.createSymlinkError = refused

        XCTAssertEqual(installation.install(),
                       .needsPrivilege(command: cliInstallCommand(binaryPath: binary,
                                                                  linkPath: link)))
        XCTAssertEqual(installation.state(), .notInstalled)
    }

    /// A missing directory that could not be created lands in the same place,
    /// and its command's own `mkdir -p` is the answer to it.
    func testAMissingDirectoryLandsInTheSameFallback() {
        fileSystem.createDirectoryError = refused
        fileSystem.createSymlinkError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))

        guard case .needsPrivilege(let command) = installation.install() else {
            return XCTFail("expected the fallback")
        }
        XCTAssertTrue(command.contains("mkdir -p"), command)
    }

    func testInstallingTwiceChangesNothing() {
        XCTAssertEqual(installation.install(), .installed)
        XCTAssertEqual(installation.install(), .alreadyInstalled)
        XCTAssertEqual(fileSystem.symlinksCreated.count, 1)
    }

    /// The readback is not decoration. A `createSymbolicLink` that returns
    /// without throwing and leaves something else at the path is reported as
    /// what it is, because "the call returned" has been accepted as evidence
    /// three times in this project and has been wrong three times.
    func testACreateThatReturnsAndDoesNotTakeEffectIsNotReportedAsSuccess() {
        fileSystem.createSilentlyDoesNothing = true

        XCTAssertEqual(installation.install(), .createdButNotVerified(.notInstalled))
    }

    // MARK: Removing

    func testRemovingOurOwnLinkTakesItAway() {
        fileSystem.addSymlink(at: link, to: binary)

        XCTAssertEqual(installation.remove(), .removed)
        XCTAssertEqual(fileSystem.removedPaths, [link])
        XCTAssertEqual(installation.state(), .notInstalled)
    }

    /// Removal is only ever safe for a link we can prove is ours. A dangling
    /// link is included in the refusal even though it is *probably* a previous
    /// install of this very app: "probably ours" is not "ours", and one rule is
    /// worth more than the convenience.
    func testRemoveRefusesAnythingThatDoesNotResolveIntoThisBundle() {
        let theirs = "/opt/homebrew/bin/keepy-uppy"
        fileSystem.addFile(theirs)
        fileSystem.addSymlink(at: link, to: theirs)
        XCTAssertEqual(installation.remove(), .refused(.linkedElsewhere(target: theirs)))

        fileSystem.entries[link] = nil
        fileSystem.reachable.remove(link)
        fileSystem.addSymlink(at: link, to: "/gone")
        XCTAssertEqual(installation.remove(), .refused(.dangling(target: "/gone")))

        fileSystem.addFile(link)
        XCTAssertEqual(installation.remove(), .refused(.occupied))

        XCTAssertEqual(fileSystem.removedPaths, [], "nothing may have been removed")
    }

    func testRemovingWhenNothingIsThereIsNotAnError() {
        XCTAssertEqual(installation.remove(), .nothingToRemove)
    }

    /// `/usr/local/bin` belongs to root in both directions.
    func testARefusedRemovalProducesItsOwnCommand() {
        fileSystem.addSymlink(at: link, to: binary)
        fileSystem.removeError = refused

        XCTAssertEqual(installation.remove(),
                       .needsPrivilege(command: cliRemoveCommand(linkPath: link)))
        XCTAssertEqual(installation.state(), .installed)
    }

    func testARemovalThatReturnsAndLeavesTheLinkIsNotReportedAsSuccess() {
        fileSystem.addSymlink(at: link, to: binary)
        fileSystem.removeSilentlyDoesNothing = true

        XCTAssertEqual(installation.remove(), .removedButStillThere(.installed))
    }

    // MARK: Where it points

    /// A user running from `~/Downloads` must get a link — and a command — that
    /// points at *their* copy, or the link points at a bundle that is not the
    /// one that made it.
    func testTheLinkAndTheCommandBothNameTheRunningBundle() {
        let elsewhere = "/Users/x/Downloads/Keepy Uppy.app/Contents/MacOS/keepy-uppy"
        let fileSystem = FakeFileSystem()
        fileSystem.addFile(elsewhere)
        let installation = CLIInstallation(fileSystem: fileSystem, directory: directory,
                                           binaryPath: elsewhere)

        XCTAssertEqual(installation.install(), .installed)
        XCTAssertEqual(fileSystem.symlinksCreated.first?.target, elsewhere)
        XCTAssertTrue(cliInstallCommand(binaryPath: elsewhere, linkPath: installation.linkPath)
            .contains(elsewhere))
    }
}

// MARK: - Where the app itself installs to

/// The one place `/usr/local/bin` is named, and the one override that reaches
/// it.
final class CLIInstallPathTests: XCTestCase {
    private let key = "KEEPY_UPPY_CLI_INSTALL_DIR"

    override func tearDown() {
        unsetenv(key)
        super.tearDown()
    }

    /// First entry in `/etc/paths`, which is what makes this the only target
    /// worth having: it is on the default `PATH` of every user of every Mac,
    /// with no Homebrew and no dotfile involved.
    func testTheShippingTargetIsTheOneDirectoryOnEveryMacsDefaultPath() {
        unsetenv(key)
        XCTAssertEqual(CLIInstallPaths.directory, "/usr/local/bin")
        XCTAssertEqual(CLIInstallPaths.defaultDirectory, "/usr/local/bin")
        XCTAssertEqual(CLIInstallPaths.linkName, "keepy-uppy")
    }

    /// **A launch environment variable, and deliberately not a `UserDefaults`
    /// key.** `PreferencesSuite` redirects only under XCTest: outside it that
    /// domain is the user's production one, which the installed Release app
    /// reads live — so a default written to point this at a scratch directory
    /// would point the *shipping* app's installer there too, and would outlive
    /// the process that wrote it. An environment variable cannot leave the
    /// process it was set on.
    func testTheOverrideIsReadFromTheEnvironmentAndOnlyInDebug() {
        setenv(key, "/tmp/somewhere-else", 1)
        #if DEBUG
        XCTAssertEqual(CLIInstallPaths.directory, "/tmp/somewhere-else")
        #else
        XCTAssertEqual(CLIInstallPaths.directory, "/usr/local/bin",
                       "a Release build must ignore it entirely")
        #endif

        // An empty value is not an override — it is an unset variable spelled
        // differently, and taking it literally would install into "/keepy-uppy".
        setenv(key, "", 1)
        XCTAssertEqual(CLIInstallPaths.directory, "/usr/local/bin")
    }
}

// MARK: - The guard on `setup` and `reset`

/// `Bundle.main` does not follow a symlink, so the two verbs that need to find
/// their own `.app` refuse rather than answer.
final class CLIBundleGuardTests: XCTestCase {
    private let realBundle = "/Applications/Keepy Uppy.app"
    private let realBinary = "/Applications/Keepy Uppy.app/Contents/MacOS/keepy-uppy"

    /// Stands in for `FileManager.fileExists`. A bundle that has both plists.
    private func completeBundle(_ path: String) -> (String) -> Bool {
        let plists = Set([CLIBundleGuard.daemonPlistPath(inBundle: path),
                          CLIBundleGuard.agentPlistPath(inBundle: path)])
        return { plists.contains($0) }
    }

    /// **The restriction is exactly two verbs, and no more.** `on`, `off`,
    /// `status`, `sessions` and `finished` are pure XPC plus `UserDefaults` and
    /// work perfectly through the link; refusing them would break the feature
    /// this guard exists to make safe.
    func testOnlySetupAndResetNeedTheAppBundle() {
        XCTAssertEqual(CLIBundleGuard.appBundleVerb(.setup), "setup")
        XCTAssertEqual(CLIBundleGuard.appBundleVerb(.reset), "reset")

        let unaffected: [CLICommand] = [
            .on(kind: .indefinite, persistence: .clientBound,
                power: PowerRequest(wakeMode: .clamshell, keepsDisksAwake: false)),
            .off(.own), .off(.all), .off(.session("x")),
            .status(json: false), .status(json: true),
            .sessions,
            .finished(tool: nil),
        ]
        for command in unaffected {
            XCTAssertNil(CLIBundleGuard.appBundleVerb(command), "\(command)")
        }
    }

    /// A real bundle with both job descriptions where `SMAppService` will look
    /// for them.
    func testABundleWithBothJobDescriptionsIsUsable() {
        XCTAssertTrue(CLIBundleGuard.isUsableAppBundle(realBundle,
                                                       exists: completeBundle(realBundle)))
    }

    /// **This is the case the guard exists for.** Invoked through
    /// `/usr/local/bin/keepy-uppy`, `Bundle.main.bundlePath` is
    /// `/usr/local/bin` — measured, in `plan7-path-symlink-research.md` §1.4.
    func testTheDirectoryASymlinkedInvocationReportsIsNotUsable() {
        XCTAssertFalse(CLIBundleGuard.isUsableAppBundle("/usr/local/bin", exists: { _ in true }))
    }

    /// The `.app` extension alone is not the question. A directory called
    /// `x.app` with nothing in it passes that and fails the thing
    /// `SMAppService` is about to do.
    func testABundleMissingItsJobDescriptionsIsNotUsable() {
        XCTAssertFalse(CLIBundleGuard.isUsableAppBundle(realBundle, exists: { _ in false }))
        // Daemon plist present, agent plist missing.
        let daemonOnly = CLIBundleGuard.daemonPlistPath(inBundle: realBundle)
        XCTAssertFalse(CLIBundleGuard.isUsableAppBundle(realBundle, exists: { $0 == daemonOnly }))
    }

    /// **Against the real filesystem, on the bundle this test is running out
    /// of.** The test host *is* the app, so this pins the guard against the
    /// thing it must never refuse — and fails the day the two plists stop being
    /// copied into the bundle, which is also the day `setup` would silently
    /// stop working.
    func testTheBundleThisTestIsRunningFromIsUsable() throws {
        let bundle = Bundle.main.bundlePath
        try XCTSkipUnless(bundle.hasSuffix(".app"),
                          "not hosted by the app bundle: \(bundle)")
        XCTAssertTrue(
            CLIBundleGuard.isUsableAppBundle(bundle,
                                             exists: { FileManager.default.fileExists(atPath: $0) }),
            "the app bundle must carry both launchd job descriptions: "
                + CLIBundleGuard.daemonPlistPath(inBundle: bundle) + ", "
                + CLIBundleGuard.agentPlistPath(inBundle: bundle))
    }

    func testNoRefusalWhenTheBundleIsUsable() {
        XCTAssertNil(CLIBundleGuard.refusal(verb: "setup",
                                            bundlePath: realBundle,
                                            resolvedExecutablePath: realBinary,
                                            exists: completeBundle(realBundle)))
    }

    /// The refusal names the command that *will* work, built from the resolved
    /// executable path — so the answer is in the message rather than in a
    /// document.
    func testTheRefusalNamesTheCommandThatWillWork() throws {
        let refusal = try XCTUnwrap(
            CLIBundleGuard.refusal(verb: "reset",
                                   bundlePath: "/usr/local/bin",
                                   resolvedExecutablePath: realBinary,
                                   exists: completeBundle(realBundle)))
        XCTAssertTrue(refusal.contains("'\(realBinary)' reset"), refusal)
    }

    /// Quoted, because the path it names has a space in it and the user is
    /// about to paste it.
    func testTheCommandInTheRefusalIsQuoted() {
        let refusal = CLIBundleGuard.refusal(verb: "setup",
                                             bundlePath: "/usr/local/bin",
                                             resolvedExecutablePath: realBinary,
                                             exists: completeBundle(realBundle)) ?? ""
        XCTAssertTrue(refusal.contains(shellSingleQuoted(realBinary)), refusal)
    }

    /// A loose copy of the binary, not a link into a bundle: there is nothing
    /// to point at, so it names the shape of the answer instead of a path that
    /// does not exist.
    func testARefusalWithNoRecoverableBundleStillSaysWhatToDo() {
        let refusal = CLIBundleGuard.refusal(verb: "setup",
                                             bundlePath: "/tmp/build",
                                             resolvedExecutablePath: "/tmp/build/keepy-uppy",
                                             exists: { _ in false }) ?? ""
        XCTAssertTrue(refusal.contains("Keepy Uppy.app"), refusal)
        XCTAssertTrue(refusal.contains("setup"), refusal)
    }

    func testEnclosingAppBundleWalksUpToTheApp() {
        XCTAssertEqual(CLIBundleGuard.enclosingAppBundle(ofResolvedExecutable: realBinary),
                       realBundle)
        XCTAssertNil(CLIBundleGuard.enclosingAppBundle(ofResolvedExecutable: "/usr/local/bin/keepy-uppy"))
    }
}

// MARK: - The real filesystem, in a throwaway directory

/// **The proof that the branch the tests above fake actually works.**
///
/// Everything here runs against the real `FileManager` conformer, the real
/// `symlink(2)`, and the real `/bin/sh` — in a fresh directory under
/// `NSTemporaryDirectory()` that is removed afterwards. It cannot reach
/// `/usr/local/bin`: every `CLIInstallation` is handed an explicit directory,
/// and nothing here reads `CLIInstallPaths.directory` at all.
///
/// The binary it links to is this app bundle's own embedded `keepy-uppy`, whose
/// path contains a space — which is the entire point of the second test.
final class CLIInstallationRealFilesystemTests: XCTestCase {
    private var scratch = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = NSTemporaryDirectory() + "keepy-uppy-cli-install-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
        try super.tearDownWithError()
    }

    /// The CLI as it actually ships: inside the app bundle this test is hosted
    /// by, at a path with a space in it.
    private func embeddedCLI() throws -> String {
        let path = Bundle.main.bundlePath + "/Contents/MacOS/" + CLIInstallPaths.linkName
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path),
                          "no embedded CLI to link to: \(path)")
        return path
    }

    /// Runs something and returns what it said. Used to prove a link is not
    /// merely a directory entry but a thing that runs.
    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return ("", "\(error)", -1) }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (out, err, process.terminationStatus)
    }

    /// **"The API returned success" is not what this asserts.** It installs,
    /// reads the link back with the filesystem's own `readlink`, and then *runs
    /// the link* — the CLI's usage line on stderr with a non-zero exit is proof
    /// that the entry resolves to a runnable binary, and it needs no daemon, no
    /// signing and no session.
    func testAnInstalledLinkResolvesToARunnableBinaryAndThenComesBackOut() throws {
        let binary = try embeddedCLI()
        let installation = CLIInstallation(fileSystem: FileManagerCLIInstallFileSystem(),
                                           directory: scratch + "/bin",
                                           binaryPath: binary)

        XCTAssertEqual(installation.state(), .notInstalled)
        XCTAssertEqual(installation.install(), .installed)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installation.linkPath),
                       binary)

        let invoked = run(installation.linkPath, [])
        XCTAssertNotEqual(invoked.status, 0, "no arguments is a usage error")
        // `cliUsage` itself, not a copy of it. This assertion is about the link
        // resolving to something that runs and complains, not about which verbs
        // exist — and a hand-written copy of the verb list here is a third copy
        // of a string that was already named once precisely to have one.
        XCTAssertTrue(invoked.err.contains(cliUsage), "stderr was: \(invoked.err)")

        XCTAssertEqual(installation.remove(), .removed)
        XCTAssertEqual(installation.state(), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installation.linkPath))
    }

    /// **The branch that will actually run on a stock Mac, executed rather than
    /// asserted about.**
    ///
    /// `/usr/local/bin` is root-owned, so the unprivileged `symlink()` above
    /// almost never succeeds and every ordinary user lands on the generated
    /// command instead. "We wrote quotes" and "`sh` parses this as intended" are
    /// different claims, and a path with a space in it — on **both** sides here
    /// — is exactly where they come apart. A test that greps its own output for
    /// a quote character passes for a command a shell would split in two.
    ///
    /// So the string is handed to a real `/bin/sh` with exactly one
    /// modification: **the privilege escalation is dropped.** The destination is
    /// a scratch directory *by construction* — it was never `/usr/local/bin` —
    /// so no part of the string is edited to redirect it.
    func testTheGeneratedCommandIsParsedByARealShellTheWayItReads() throws {
        let binary = try embeddedCLI()
        // A space on the destination side too, which the real path does not
        // have: if the quoting is right it is right for both.
        let installation = CLIInstallation(fileSystem: FileManagerCLIInstallFileSystem(),
                                           directory: scratch + "/root owned bin",
                                           binaryPath: binary)
        let command = cliInstallCommand(binaryPath: binary, linkPath: installation.linkPath)

        XCTAssertTrue(command.hasPrefix("sudo "), command)
        XCTAssertTrue(binary.contains(" "), "the proof depends on the space: \(binary)")

        let asRun = command.replacingOccurrences(of: "sudo ", with: "")
        // Printed, not merely asserted about. The evidence this test exists to
        // produce is a transcript somebody can read — "the assertions passed" is
        // the form of proof this project has been burned by, and a reader
        // re-running this should be able to see the exact characters that were
        // handed to `sh`.
        print("generated: \(command)")
        print("as run:    \(asRun)")

        let shell = run("/bin/sh", ["-c", asRun])
        XCTAssertEqual(shell.status, 0, "sh said: \(shell.err)")
        print("readlink:  "
              + ((try? FileManager.default.destinationOfSymbolicLink(atPath: installation.linkPath)) ?? "«none»"))

        // The shell made a link, and it is the link the app would have made.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installation.linkPath),
                       binary, "the space did not survive the shell")
        XCTAssertEqual(installation.state(), .installed)

        let invoked = run(installation.linkPath, [])
        XCTAssertNotEqual(invoked.status, 0)
        XCTAssertTrue(invoked.err.contains("usage: keepy-uppy"), "stderr was: \(invoked.err)")
    }

    /// The install command refuses to overwrite, in a real shell — the reason
    /// there is no `-f` on it.
    func testTheGeneratedInstallCommandFailsRatherThanClobbering() throws {
        let binary = try embeddedCLI()
        let directory = scratch + "/bin"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let occupant = directory + "/" + CLIInstallPaths.linkName
        try "not a symlink".write(toFile: occupant, atomically: true, encoding: .utf8)

        let installation = CLIInstallation(fileSystem: FileManagerCLIInstallFileSystem(),
                                           directory: directory, binaryPath: binary)
        XCTAssertEqual(installation.state(), .occupied)

        let command = cliInstallCommand(binaryPath: binary, linkPath: installation.linkPath)
        let shell = run("/bin/sh", ["-c", command.replacingOccurrences(of: "sudo ", with: "")])
        XCTAssertNotEqual(shell.status, 0, "ln -s must refuse an occupied path")
        XCTAssertEqual(try String(contentsOfFile: occupant, encoding: .utf8), "not a symlink")
    }

    /// And the replace command, which is the only one offered with `-f`, does
    /// take over a dangling link — also in a real shell.
    func testTheGeneratedReplaceCommandTakesOverADanglingLink() throws {
        let binary = try embeddedCLI()
        let directory = scratch + "/bin"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let installation = CLIInstallation(fileSystem: FileManagerCLIInstallFileSystem(),
                                           directory: directory, binaryPath: binary)
        try FileManager.default.createSymbolicLink(atPath: installation.linkPath,
                                                   withDestinationPath: scratch + "/gone")
        XCTAssertEqual(installation.state(), .dangling(target: scratch + "/gone"))

        let command = try XCTUnwrap(installation.fallbackCommand(for: installation.state()))
        let shell = run("/bin/sh", ["-c", command.replacingOccurrences(of: "sudo ", with: "")])
        XCTAssertEqual(shell.status, 0, "sh said: \(shell.err)")
        XCTAssertEqual(installation.state(), .installed)
    }
}
