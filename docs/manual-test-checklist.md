<!-- Moved out of the README: it is a working document for whoever is
changing this code, not something a reader evaluating the project needs. -->

# Manual test checklist

Run through this after any change to the menu-bar app, the daemon, the agent,
or the CLI. Most of it can only be checked on a signed build with the
background services actually registered — which is exactly why it is a manual
list and not a test suite.

Two items are stale placeholders from an earlier design and are deliberately
left unticked rather than deleted, because the behaviour they describe still
wants checking under the current one: the per-connection "rate limited" wording
predates the detached-session sub-cap that replaced it.

**Menu-bar app basics:**
- [ ] Clicking the icon (left or right click, both open the same menu) shows correct status text, toggle wording, and login-item checkbox state
- [ ] The app has no Dock icon and shows the balloon in the menu bar
- [ ] The app's Finder/Get Info icon shows the balloon
- [ ] The exported, notarized `.app` opens without Gatekeeper warnings
- [ ] "Launch at Login" registers/unregisters and is reflected in System Settings → General → Login Items

**Settings → General (onboarding & enablement):**
- [ ] Fresh install: open the app, Settings → General shows "Not enabled"; clicking "Enable Keepy Uppy" registers both background items and, if approval is needed, opens System Settings to the right pane
- [ ] After approval, Settings → General shows "Running" without needing to reopen the app
- [ ] Daemon and agent both register and appear as "Keepy Uppy" in Login Items
- [ ] Approving once is enough; no later prompts

**Settings → General (the default wake mode):**

The picker's *copy* is pinned by `SessionDisplayTests`; how it lays out, and
what changing it does to a menu and to a session already running, is not
observable from any test.

- [ ] Under "Default session" there is a "Keeps this Mac awake" picker offering exactly three options — "Even with the lid closed", "Only with the lid open", "Only with the lid open, screen on" — and the footer text under it changes as you move between them
- [ ] Both footer paragraphs (the changing explanation, then "Sessions you start from the menu from now on use this…") wrap and stay readable at the Settings window's default width with the longest option selected — they are the two longest strings in the window and neither is truncated or clipped
- [ ] Pick "Only with the lid open", open the menu: every "Keep awake …" row now ends "(lid open only)". Start one, and its stop row reads "Stop this session (lid open only)" with the machine-wide line "Closing the lid will still let this Mac sleep." above it
- [ ] Change the picker back to "Even with the lid closed" while that session is still running: the running session's tag and the lid line do **not** change (a mode is fixed when the session starts — that is exactly what "from now on" in the footer is warning about), and the next session started from the menu has no tag
- [ ] With the picker on "Only with the lid open", let a **trigger** fire: the session it starts is still lid-safe, so the "Closing the lid…" line is absent while it runs. Triggers deliberately ignore this preference
- [ ] The longest rows this menu can produce are not truncated: with two of your own "Only with the lid open, screen on" sessions live, a stop row reads `Stop “7h 59m left” (screen on, lid open only)`, and a `keepy-uppy on --while-app com.apple.dt.Xcode --keep-display-awake` session alongside them reads `While Xcode is running — started from the command line (screen on, lid open only)`

**Settings → Safety:**
- [ ] Settings → Safety: lowering the battery cutoff and confirming (via `keepy-uppy status`) the daemon picks it up within ~5s without restarting anything

**Settings → Triggers:**

A trigger session **is** tagged as automatic in the menu as of Plan 7 Task 3,
and these items are written to match. Before it, the daemon's stamping of
`owner` from the accepting listener's role — an agent-started session is owned
by `agent-<uid>`, not `app-<uid>` — meant every such session failed
`MenuContent`'s one equality test and rendered `… — started elsewhere`,
indistinguishable from the CLI's or another user's. `menuSessionGroup` now
splits that bucket by `ownerUID` and owner role, so a trigger of your own reads
`… — started automatically` and a `keepy-uppy on` session of your own reads
`… — started from the command line`.

**None of the three gained a stop button, and that half is still open.** This
app cannot end a session it did not start — `SessionIsolation` scopes every
stop to the caller's own `ClientID` — so a running trigger session can only be
ended by `keepy-uppy off --all`, by its condition, or by its duration.
Disabling the rule does not end a session it already started. That is a
`SessionIsolation` change (spec §4), not something to fix by editing this list.

- [ ] Settings → Triggers: adding an "App Launched" rule for a real installed app, launching it, confirming a session starts automatically and shows up in the menu as an unclickable row reading `Indefinite — started automatically` (or `Xh Ym left — started automatically` for a timed `defaultKind`), and keeps running for `defaultKind`'s picked duration — quitting that app does NOT end it early (a trigger starts a session, it doesn't bind that session's lifetime to the condition; `.processRunning` below is the one deliberate exception)
- [ ] A trigger does not fire again while its session is still active (leave the triggering app running, confirm no duplicate session appears)
- [ ] Triggering a real safety stop (or lowering the thermal sensitivity to `cautious` under load) suppresses a trigger from firing again until the configured cooldown elapses, while a manual "Start…" click still works immediately
- [ ] Settings → Triggers: adding a process-running rule via a quick-add preset (e.g. Claude Code), running `claude` in a terminal, confirming a session starts within ~5s and appears in the menu as `While claude is running — started automatically` (unclickable, for the reason above), and that the duration picker plays no part; quitting `claude` ends the session within ~10s (two 5s ticks — `sessionsToEnd` needs `SessionEvidence.negativesBeforeEnding` consecutive confident negatives, so a single bad reading can never end a session)
- [ ] The Cursor CLI and Pi presets show the generic-name collision warning; the other three presets don't
- [ ] Typing a *path* (`/opt/homebrew/bin/claude`) rather than a name into the process field is rejected in the sheet with an explanation, rather than being accepted as a rule that could never fire
- [ ] A process-running rule for a `node`/`bun`-wrapped CLI (`claude`, installed by npm as a `claude` symlink to `claude.exe`) really does fire — this is the case `p_comm` matching alone could not see, since the kernel records `claude.exe` there and only `argv[0]` ever says `claude`
- [ ] `keepy-uppy on --while-process <name>` behaves like `--while-app`, ending within ~10s of that process exiting

**The frontmost-app, volume and network conditions.** All three read something
a test target has no way to hold still: which app owns the front, what is
mounted, and what address this Mac holds. The observers are unit-tested against
fake readers; what follows is the half that needs a real desk.

- [ ] Add an "An app comes to the front" rule for an app you can leave running. Launch it and leave it *behind* another window: no session starts. Now click it to the front: a session appears in the menu within ~5s. Send it to the back again and the session keeps running — this condition is a starting gun, not a lifetime, and its row in Settings → Triggers should say `When <app> comes to the front` over `Starts a session that keeps this Mac awake …`, never a "While …" line
- [ ] With that rule live, lock the screen (or fast-user-switch to another account) for a minute and come back. No session was started while the screen was locked, and any session that was already running is still running — `frontmostApplication` is `nil` in both states, and that has to read as "I don't know", never as "the app went away"
- [ ] `keepy-uppy on --while-volume <name>` with an external drive attached: start a large copy *to* that drive and confirm the session does not end while it runs, then eject the drive and confirm the session ends within ~10s (two 5s ticks)
- [ ] Attach an enclosure whose filesystem does **not** mount (an unformatted or unreadable disk, or one you decline to initialise): a `volumeMounted` rule for it does not fire. The condition is "mounted", not "plugged in" — that is what `--while-usb` is for
- [ ] Open Settings → Triggers → Add → "A volume is mounted" and drop the "Mounted…" menu: it names exactly what Finder's sidebar names — `Macintosh HD` plus whatever is plugged in — and none of `VM`, `Preboot`, `Update`, `xART`, `iSCPreboot`, `Hardware` or a simulator runtime. A hidden volume offered here is a rule somebody can write and never understand
- [ ] `keepy-uppy on --while-subnet <your block>` survives a Wi-Fi roam between two access points on the same network (walk between them, or toggle between two bands of the same SSID), and ends within ~10s of joining a different network entirely
- [ ] Turning Wi-Fi off entirely ends a `--while-subnet` session within ~10s; so does unplugging Ethernet on a wired Mac. Neither should take longer than two ticks, and neither should end a `--for` session running alongside it
- [ ] With a `--while-subnet` session live on a Wi-Fi block, dock to Ethernet on the same network: the session **survives**, because the block matches whichever interface holds the address. This is the behaviour a Wi-Fi-name trigger could not have had, and it is the reason there isn't one
- [ ] Install a build from before these conditions existed over one from after (or the reverse), open Settings → Triggers, change something unrelated, and confirm the rules the older build could not read are still there when the newer one comes back. The older build hides them and counts them; it must not write them away

**The VPN condition — the one half of it no test can reach.**
`SCDynamicStoreVPNServiceReader` was verified with a real (split-tunnel) VPN
connected, and against the eight non-VPN `utun` interfaces that share the
machine with it, but **the transition was never observed**: there was exactly
one VPN configured and it was up, a non-root process cannot plant a fake one
(`SCDynamicStoreSetValue` → "Permission denied"), and disconnecting the user's
VPN was out of scope. `.superpowers/sdd/plan5-vpn-research.md` has the
measurements. These two items are the missing half.

- [ ] With a VPN connected, `keepy-uppy on --while-vpn` starts a session; disconnecting the VPN ends it within ~10s (two 5s ticks), and it does **not** end when the VPN merely reconnects
- [ ] With no VPN connected, a `vpnActive` trigger does nothing; connecting one starts a session within ~5s reading `While a VPN is connected — started automatically`, and it survives a Wi-Fi hop that leaves the tunnel up
- [ ] Turn **iCloud Private Relay on** with no VPN connected, wait a minute, and confirm a `vpnActive` trigger stays quiet and `keepy-uppy on --while-vpn` refuses to stay up. Private Relay adds another `utun` to the eight this Mac already carries, so this is the false-positive check that decides whether the condition is honest rather than merely permanently true
- [ ] On a Mac with **no VPN configured at all**, a live `--while-vpn` session ends rather than hanging — an empty answer is a confident negative here, deliberately unlike the volume observer's
- [ ] The Add-trigger sheet's "A VPN is connected" row shows the limitation footnote naming wg-quick/openvpn/Tunnelblick, and a tunnel started by one of those really is *not* detected (this is the stated limitation, not a bug to file)

**The USB condition — the half no test could reach either.**
`IOKitUSBDeviceReader` was written and verified on a Mac with **nothing plugged
into it**: three USB host controllers and zero devices, agreed independently by
`ioreg -p IOUSB` and `system_profiler SPUSBDataType`. So the enumeration
machinery, the class name and the property names are all established (see
`.superpowers/sdd/plan5-device-research.md`) but *a real device appearing in the
list* never was. That is what these items are for.

- [ ] Plug something in and open the Add-trigger sheet: "Attached…" lists it **by name**, picking it fills the field with `0x….0x…`, and the saved rule's row names the device rather than the hex
- [ ] `system_profiler SPUSBDataType` and the "Attached…" menu list the same devices — a device in one and not the other means the class or property names are wrong
- [ ] With that device unplugged, the rule's row falls back to `0x05ac:0x024f`-style identifiers rather than going blank
- [ ] `keepy-uppy on --while-usb <vid>:<pid>` with the device attached starts a session; unplugging it ends the session within ~10s, and re-plugging within one tick does not
- [ ] Two devices from the same vendor: a rule for one does **not** fire for the other (both identifiers have to match)
- [ ] A hub with devices behind it: the devices behind it are listed, and unplugging the hub ends a session bound to one of them

**Bluetooth is deliberately absent**, not missing. It was specified alongside
USB and cut on the research: `bluetoothd` enforces `kTCCServiceBluetoothAlways`
and can raise the dialog, neither the app nor the agent carries a Bluetooth
usage description, and the observer would run in a background LaunchAgent whose
worst case is termination — taking every other trigger with it. There is
nothing to test; the argument and the one experiment that would settle it are in
`.superpowers/sdd/plan5-device-research.md`.

**A Wi-Fi SSID condition is deliberately absent too**, and for a related reason
with a different mechanism. `CWInterface.ssid()` is gated on Location Services,
and the gate is silent: measured on a Mac with a live association
(`rssiValue == -51`, an 802.11ax link on channel 36), an ad-hoc-signed binary
read `ssid() == nil` with no dialog — the same answer a Mac with Wi-Fi switched
off would give. And the grant is unobtainable where it is needed:
`CLLocationManager`'s header says an authorization request from something not
currently in use "will do nothing", which is exactly the UI-less LaunchAgent
that would have to read it. So there is no `--while-wifi` and no SSID row in the
Add sheet; `.onSubnet` is the supported way to say "while I am on that network",
and it covers Ethernet on the same network as well.
`.superpowers/sdd/plan5-wifi-research.md` has the measurements.

- [ ] Add-trigger sheet → "This Mac is on a network": the footnote says plainly that this is how a Wi-Fi network is named here, and why it is matched by address block rather than by name — a user looking for a Wi-Fi trigger must not be left hunting for one
- [ ] While on Wi-Fi, "This Mac…" offers the block that Mac's Wi-Fi address sits in, and a rule built from it fires — i.e. the Wi-Fi case really is served by this condition
- [ ] **Nothing, anywhere in the app, ever raises a Location Services prompt** — including opening the Add sheet on this row, saving a network rule, and letting the agent run with one live
- [ ] The broader version of that, because the README now promises it: save one rule of **every** condition kind, leave the agent running for an hour with an external drive and a USB device attached, and confirm no privacy dialog of any kind appears (Location, Bluetooth, Files and Folders, removable volumes, Accessibility). Then open System Settings → Privacy & Security and confirm Keepy Uppy appears under nothing but Login Items — a grant that was never asked for still shows up there once something triggers it
- [ ] Settings → Triggers → On Session End: configuring a script and a webhook URL (e.g. `https://webhook.site/...`), then ending a session manually from the menu, confirms both fire within ~5s
- [ ] `keepy-uppy finished` (with a script/webhook configured) runs immediately and the CLI process doesn't exit before the webhook POST actually leaves the machine — works even with the daemon not running
- [ ] `keepy-uppy finished --tool claude-code` threads `--tool` through to the script's `KEEPY_UPPY_TOOL` env var and the webhook JSON's `"tool"` field
- [ ] Wiring an actual Claude Code `SessionEnd` hook to call `keepy-uppy finished --tool claude-code` fires the configured action at real task completion, not just when the `claude` process eventually exits
- [ ] The script's `KEEPY_UPPY_KIND` and the webhook JSON's `"kind"` carry the stable wire strings (`while-app-running:com.apple.dt.Xcode`, `duration`, …), never Swift's `whileAppRunning(bundleID: "…")` debug syntax
- [ ] Choosing a non-executable file (a `chmod 644` script) in Settings → Triggers → On Session End is refused in the tab with a message naming the real reason, rather than being saved and failing later in the log as "The file … doesn't exist."
- [ ] Fast-user-switch to a second account, start a session there, switch back and end it: the *first* user's script and webhook do NOT fire, and nothing carrying the second user's app/process name reaches them
- [ ] Restarting the daemon while several sessions are running does not fire the completion action once per session as they all vanish at once
- [ ] A webhook endpoint answering `307` to a different host does not deliver the POST to the redirect target (the agent logs "refused a 307 redirect")
- [ ] A `.whileOnACPower` session survives a transient power-source read failure — it must end only on a real unplug, never on IOKit declining to answer

**Menu-bar app session control:**
- [ ] Menu "Start… → Indefinitely" keeps the Mac awake with the lid closed; quitting the app ends that session (clientBound) and sleep resumes
- [ ] A session started via `keepy-uppy on --for 2h` (detached) is NOT ended by quitting the menu-bar app, and appears in the menu's session list with the right remaining time
- [ ] Quitting the app while it owns an active session ends that session (no prompt); sessions owned by other clients (CLI, other logins) are left running

**CLI and daemon/agent behavior:**
- [ ] `keepy-uppy setup` registers both background items; approving once is enough
- [ ] `keepy-uppy on --for 30s` starts a session that ends on its own after 30 seconds
- [ ] `keepy-uppy on --while-app <bundle id>` ends within ~5s of quitting that app
- [ ] `keepy-uppy on --while-display` ends within ~10s of unplugging the external screen, and `keepy-uppy on --while-ac-power` ends within ~5s of the charger coming out — the three kinds these flags reach were evaluated by the daemon and the agent for two plans before any client could ask for one, so this is the first time either path runs against a session a user actually started
- [ ] `keepy-uppy on --while-ac-power` on battery is refused up front (`conditionNotMet`) rather than starting a session that ends on its own first tick, and `--while-display` / `--while-cpu-busy` with the agent killed are refused with the no-agent message rather than starting a session nothing can ever end
- [ ] `keepy-uppy on --while-cpu-busy 30` survives a lull shorter than two minutes under a real build, and ends about two minutes after the CPU settles below 30% — and the menu row for it reads `While the CPU is at least 30% busy — started from the command line`, naming the number that was typed
- [ ] An external `sudo pmset -a disablesleep 1` does **not** stick: the daemon rewrites the setting from its own session table on every 5s tick, so with no session live `pmset -g | grep -i sleepdisabled` is back to `0` within ~5s and the icon does not latch on. The converse too — clearing it by hand while a default-mode session runs is undone on the next tick, and the session goes on being honoured
- [ ] `keepy-uppy reset` with a default-mode session live prints how many sessions it ended, and `pmset -g | grep -i sleepdisabled` reads `0` **before** anything is unregistered — the eviction must never be the last thing that touches a Mac still being held awake, because it removes the only process that could ever clear that setting and the setting survives a reboot
- [ ] `keepy-uppy reset` on a machine with no daemon registered still unregisters cleanly, exits 0, and prints the "did not answer" note on stderr rather than refusing — that half-installed state is what the verb is for. The note reports what `SleepDisabled` actually reads on that machine (the CLI performs that read itself; only the repair needs root), so with the setting left at `1` by hand it must name `sudo pmset -a disablesleep 0` and with the setting off it must not
- [ ] With a default-mode session live, SIGTERM to the daemon (`sudo launchctl kill -TERM system/au.com.workwireless.keepy-uppy.helper`) leaves `pmset -g | grep -i sleepdisabled` reading `0` — the daemon converges the persistent axis on the way out, so `launchctl bootout`, an upgrade, and the eviction `reset` performs can no longer strand a Mac awake. This is the one item that covers the handler at all: `Helper/main.swift` is top-level executable code no test target can reach
- [ ] …and the same with `-KILL` instead does **not** clear it immediately — SIGKILL is uncatchable, and the setting stays at `1` until something relaunches the daemon and `DaemonRuntime.start()`'s converge-to-safe clears it. That asymmetry is the point: it is why converge-at-launch stays, rather than being replaced by the handler
- [ ] Killing the agent process (Activity Monitor) does not end `--for`/indefinite sessions, but does end `--while-app` ones
- [ ] Deleting the app while a session is active restores sleep
- [ ] Two terminals opening 25 sessions each are individually capped at 20 and rate-limited within each connection

**Wake modes (`on`'s second axis):**

Only the first item here is checkable from a test suite; the rest are the
whole reason `SleepDisabled` and `IOPMAssertion` are both held, and neither
mechanism's real behaviour is observable without a physical lid and a real
idle timer.

- [ ] `keepy-uppy on --display-may-sleep --keep-display-awake` is refused with a message naming both flags, and starts nothing
- [ ] `keepy-uppy on` with no wake-mode flag still keeps the Mac awake with the lid **closed** — the pre-existing default must be unchanged
- [ ] `keepy-uppy on --display-may-sleep` keeps the machine running while the display goes dark on its normal idle timer (check with `pmset -g assertions`: `PreventUserIdleSystemSleep` held, `PreventUserIdleDisplaySleep` not)
- [ ] …and that session does **not** survive closing the lid — assertions never do; only the global setting does
- [ ] `keepy-uppy on --keep-display-awake` also holds the display on (`PreventUserIdleDisplaySleep` in `pmset -g assertions`), and likewise does not survive a lid close
- [ ] **The open question this checklist exists to close.** With `keepy-uppy on --for 30m --keep-display-awake` running, leave the Mac completely untouched for longer than the screensaver's idle interval (System Settings → Lock Screen → "Start Screen Saver when inactive" — on an unmanaged Mac the value is an OS default with no readable key behind it, so read it off that pane rather than from `defaults`). Watch the screen. **Does the screensaver start?** Record either answer.
  - Why it is open: the assertion holds the display's *power state* — it does not dim and does not turn off — but it demonstrably does **not** stop the HID idle clock. Measured in `.superpowers/sdd/plan6-display-sleep-research.md`: `HIDIdleTime` climbed 43.275 s over 43 wall-clock seconds while `PreventUserIdleDisplaySleep` was held. Whether `loginwindow` starts the screensaver off *that* clock is an inference nobody has checked.
  - If the screensaver **does** start: the Settings copy for "Only with the lid open, screen on" gains one sentence, written out ready to paste in that research document. Until then the copy is deliberately silent on screensavers in both directions, and `SessionDisplayTests` pins that silence.
  - Do not shorten the wait by triggering the screensaver from a hot corner or `open -a ScreenSaverEngine` — that answers a different question. Only the idle timer counts.
- [ ] With a `--display-may-sleep` session and a default (clamshell) session running at once, the lid-closed guarantee is back — the daemon unions the two, it does not pick one
- [ ] Ending only the clamshell session of that pair drops the lid-closed guarantee but leaves the machine awake with the display free to sleep
- [ ] Either wake-mode flag prints a one-line note naming that flag and saying it does not keep the Mac awake with the lid closed — and it goes to **stderr**: `keepy-uppy on --for 30s --keep-display-awake 2>/dev/null` prints only "Started session …", and `1>/dev/null` prints only the note
- [ ] `keepy-uppy sessions` shows each session's mode, so a `--display-may-sleep` session is distinguishable from a default one (`status` and `status --json` are deliberately unchanged — both still say "keeping awake" for every mode)
- [ ] With only a `--display-may-sleep` session live, `keepy-uppy status --json` still prints exactly `{"keepingAwake": true}` and `keepy-uppy sessions` prints only session rows — a script written before wake modes existed must not start finding a note or a new field on stdout

The rest are about the two mechanisms *behind* the modes. Neither is visible
from any client's output, and both have failure modes that look exactly like
success until the machine is on battery in a bag.

- [ ] The headline claim, unattended and on battery: `keepy-uppy on --for 8h` with no flag, then unplug the charger, start a long build, shut the lid and walk away. The build is still running — not resumed on opening — when you come back, and `pmset -g log | grep -i "entering sleep"` shows nothing from that window. This is the harder version of the lid check above: nothing in the suite can reach it, and it is the whole reason `SleepDisabled` is held at all
- [ ] `pmset -g | grep -i sleepdisabled` reads `1` while any default-mode session is live, and `0` once the last one ends (immediately on `keepy-uppy off`, within one 5s tick if it ended on its own clock). This one has no refcount of its own — a stuck `1` leaves the Mac unable to sleep at all, and nothing in the UI would say so
- [ ] `pmset -g assertions` attributes `PreventUserIdleSystemSleep` to Keepy Uppy while any session is live, whatever its mode, and lists nothing of ours once the last session ends — a leaked assertion is invisible in `pmset -g` and survives every client quitting
- [ ] Kill `KeepyUppyHelper` from Activity Monitor mid-session: `pmset -g assertions` is clean immediately (assertions are per-process, and `powerd` reaps a dead holder's), and `SleepDisabled` is back to `0` a moment later, when launchd restarts the helper and its startup clears it unconditionally. Sessions are in-memory, so the menu should show "Not keeping awake" rather than a session it can no longer honour

**Plan 6 behaviours (disks, display):**

The screensaver question this plan opened is **the item above** — "The open
question this checklist exists to close", under Wake modes. It is not repeated
here, and running it is what finishes `wakeModeSettingsExplanation`'s copy for
"Only with the lid open, screen on" in one direction or the other.

- [ ] `keepy-uppy on --keep-disks-awake`, then `pmset -g assertions`: a `PreventDiskIdle` row appears at 1, with `Keepy Uppy` named as the owning process underneath. (`pmset` suppresses the row while the level is 0 and prints it once it is not — so its absence beforehand and presence now is the whole check. No C API needed.)
- [ ] ...and the row goes away within a moment of that session ending; two sessions wanting it means the last one to end is what releases it
- [ ] `--keep-disks-awake` combines with `--display-may-sleep` and with `--keep-display-awake`; it is a third axis, not a wake mode, and no combination is refused
- [ ] An external drive that would otherwise spin down stays spun up through a long idle period with such a session live (an enclosure with its own firmware timer may still spin down — that is the documented limitation, not a bug)
- [ ] A network share is NOT kept alive, and the README says so — this item exists to confirm we did not quietly ship a half-working touch
- [ ] With a `--keep-disks-awake` session live, `keepy-uppy status --json` still prints exactly `{"keepingAwake": true}` — a script written before this plan must not start finding a new field, and `sessions` is where the axis is reported (`wake=…; attached disks held awake`)
- [ ] Settings → General's "Keep attached disks awake" switch is what a menu-started session uses, and the menu's start rows carry `(disks stay awake)` while it is on — a live session's own row deliberately does not, because the assertion is machine-wide and `pmset -g assertions` is where that truth lives

**Global keyboard shortcuts (Plan 7):**

**This is the one feature in the app with no self-verification available**, and
these items are not a formality. A registered hot key that never fires is
indistinguishable, from inside the process, from one that fires into a handler
nobody wired up: `RegisterEventHotKey` returns `noErr` either way. The suite
covers everything between the window server and the action — the handler is on
the right target, decodes `EventHotKeyID`, checks the signature, dispatches to
the right action, and stops when the centre is stopped — by sending a real
`kEventHotKeyPressed` to that target. **The link it cannot close is the window
server delivering a key a human pressed**, and that is what the first item here
is. Nothing else in this file substitutes for it.

- [ ] Set a shortcut in Settings ▸ CLI & Advanced, then press it **with another
  app full-screen and the Keepy Uppy menu closed**. The session starts. This is
  the whole feature: a shortcut that only works with the menu open is a menu
  shortcut, which this deliberately is not
- [ ] Set the second shortcut too, and press it. The sessions **you started from
  the menu** end — and a session started by a trigger rule, or by `keepy-uppy
  on` in a terminal, **keeps running**. That is the documented scope, not a bug:
  `stopAllSessions(all: false)` reaches `app-<uid>` only. The row says so, and
  this item exists to confirm the row is telling the truth
- [ ] Bind a combination macOS itself owns (⌘Space, say). The row warns that
  macOS uses it and the key will never arrive — **and note that no error was
  returned**: the registration genuinely succeeded. This is the case
  `kEventHotKeyExclusive` is silent about, and the warning comes from
  `CopySymbolicHotKeys`, not from the registration failing
- [ ] Bind a combination another running app already owns *without* using
  `RegisterEventHotKey` exclusively — a text-expander or window-manager
  shortcut is the usual case. **Nothing warns, and the shortcut does nothing.**
  This is the failure the standing note in that pane exists for; confirm the
  note is visible without having to do anything to provoke it
- [ ] Clear a shortcut with the Clear button and press the old combination: it
  does nothing, **immediately**, without quitting the app. A stale registration
  would go on holding the combination away from whatever you rebind it to
- [ ] Change a shortcut to a different combination and press both: the new one
  works, the old one does nothing
- [ ] Press ⌘W while recording: it is captured as a binding rather than closing
  the Settings window. Press Escape while recording: it cancels and leaves the
  previous binding alone
- [ ] Quit the app and press a bound combination: nothing happens. (The system
  unregisters at process termination — `UnregisterEventHotKey`'s own header
  paragraph — so this confirms the registration died with the process. The
  *binding* survives in preferences, which is why it works again on relaunch)

**Safety guards:**
- [x] A Release build refuses XPC connections from an unsigned binary
- [x] A non-agent client's condition report is rejected and logged
- [ ] The thermal guard stops a session at the configured sensitivity (default Balanced), and the same trigger does not immediately restart it (cooldown/hysteresis, spec §7)
- [ ] The maximum-duration backstop ends even an indefinite session
- [ ] Thermal and battery thresholds tighten when the lid is closed and the warn-then-act grace period is skipped, since there's nobody to see the warning
- [ ] Low-battery auto-off re-enables sleep and posts a notification when tested with a lowered threshold — completes unattended, with no prompt, including with the lid closed

