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

**Settings → Safety:**
- [ ] Settings → Safety: lowering the battery cutoff and confirming (via `keepy-uppy status`) the daemon picks it up within ~5s without restarting anything

**Settings → Triggers:**
- [ ] Settings → Triggers: adding an "App Launched" rule for a real installed app, launching it, confirming a session starts automatically and is tagged "Started automatically" in the menu; quitting that app ends the session within ~5s
- [ ] A trigger does not fire again while its session is still active (leave the triggering app running, confirm no duplicate session appears)
- [ ] Triggering a real safety stop (or lowering the thermal sensitivity to `cautious` under load) suppresses a trigger from firing again until the configured cooldown elapses, while a manual "Start…" click still works immediately

**Menu-bar app session control:**
- [ ] Menu "Start… → Indefinitely" keeps the Mac awake with the lid closed; quitting the app ends that session (clientBound) and sleep resumes
- [ ] A session started via `keepy-uppy on --for 2h` (detached) is NOT ended by quitting the menu-bar app, and appears in the menu's session list with the right remaining time
- [ ] Quitting the app while it owns an active session ends that session (no prompt); sessions owned by other clients (CLI, other logins) are left running

**CLI and daemon/agent behavior:**
- [ ] `keepy-uppy setup` registers both background items; approving once is enough
- [ ] `keepy-uppy on --for 30s` starts a session that ends on its own after 30 seconds
- [ ] `keepy-uppy on --while-app <bundle id>` ends within ~5s of quitting that app
- [ ] External `sudo pmset -a disablesleep 1/0` is reflected in the icon within 30 seconds
- [ ] Killing the agent process (Activity Monitor) does not end `--for`/indefinite sessions, but does end `--while-app` ones
- [ ] Deleting the app while a session is active restores sleep
- [ ] Two terminals opening 25 sessions each are individually capped at 20 and rate-limited within each connection

**Safety guards:**
- [x] A Release build refuses XPC connections from an unsigned binary
- [x] A non-agent client's condition report is rejected and logged
- [ ] The thermal guard stops a session at the configured sensitivity (default Balanced), and the same trigger does not immediately restart it (cooldown/hysteresis, spec §7)
- [ ] The maximum-duration backstop ends even an indefinite session
- [ ] Thermal and battery thresholds tighten when the lid is closed and the warn-then-act grace period is skipped, since there's nobody to see the warning
- [ ] Low-battery auto-off re-enables sleep and posts a notification when tested with a lowered threshold — completes unattended, with no prompt, including with the lid closed

