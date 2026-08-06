# Keepy Uppy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Keepy Uppy, a signed/notarizable Rust menu-bar app that keeps a MacBook awake with the lid closed by toggling `pmset -a disablesleep`.

**Architecture:** A single `keepy-uppy` binary crate split into a system-logic layer with no AppKit dependency (`power.rs` for `pmset` interaction, `login_item.rs` for `SMAppService`) and an AppKit UI layer (`app_delegate.rs` + `main.rs`) built directly on `objc2`/`objc2-app-kit`/`objc2-foundation`/`objc2-service-management`. The status bar icon and menu are always redrawn from a fresh `pmset -g` read, never from an assumption about what a prior command did.

**Tech Stack:** Rust (2021 edition), `objc2` 0.6.4, `objc2-app-kit` 0.3.2, `objc2-foundation` 0.3.2, `objc2-service-management` 0.3.2, `pmset`/`osascript` via `std::process::Command`, `just` for build/packaging, `codesign`/`notarytool`/`hdiutil` for distribution.

## Global Constraints

- Target macOS 13+ (Ventura) — this is the floor set by `SMAppService` (login item management) and is declared as `LSMinimumSystemVersion` `13.0` in `Info.plist`.
- Pin these exact crate versions (verified against crates.io on 2026-08-06 — do not bump without re-verifying the API surface): `objc2 = "0.6.4"`, `objc2-app-kit = "0.3.2"`, `objc2-foundation = "0.3.2"`, `objc2-service-management = "0.3.2"`.
- Do not use code from `objc2`'s `main` branch examples as a reference — the unreleased branch's macro syntax has already drifted from the published 0.6.4 API used throughout this plan.
- Bundle identifier: `au.com.workwireless.keepy-uppy`. Display name: "Keepy Uppy". Binary/crate name: `keepy-uppy` (kebab-case).
- Privilege model: every privileged state change goes through `osascript -e '... with administrator privileges'`, producing the native macOS auth dialog. No sudoers modification, no privileged helper daemon, nothing installed outside the `.app` bundle (spec §5).
- `objc2-app-kit` and `objc2-foundation` gate almost every class behind a Cargo feature named exactly after that class. If `cargo build` reports an unresolved type or trait, add that exact name to the relevant crate's `features` list in `Cargo.toml` — this is expected friction with these crates, not a defect in this plan.
- **Known API risk** — these three spots were not independently source-verified against docs.rs during research (everything else in this plan was). If `cargo build` fails on these specific lines, check `docs.rs/objc2/0.6.4` and `docs.rs/objc2-foundation/0.3.2` before improvising a different approach:
  1. Defining custom Objective-C selectors (e.g. `toggleClicked:`) via a plain inherent `impl AppDelegate { #[unsafe(method(...))] ... }` block placed inside `define_class!`, alongside (not instead of) the `NSApplicationDelegate` protocol impl block (Task 7, Task 8).
  2. Coercing `&AppDelegate` to `&AnyObject` via `let target: &AnyObject = self;` for `setTarget` calls (Task 7).
  3. The exact `NSUserNotification`/`NSUserNotificationCenter` method names for posting the low-battery notification (Task 8) — this is long-stable but deprecated API that the research pass didn't cover.
- Testing: `power.rs`'s parsing functions are pure and unit-tested with `cargo test`. Everything touching AppKit cannot be unit-tested; each AppKit task's "test" step is `cargo build` (or `cargo run` for a visual check) plus an entry in the manual test checklist built in Task 11.

---

### Task 1: Project scaffold

**Files:**
- Create: `Cargo.toml`
- Create: `src/main.rs`

**Interfaces:**
- Produces: a binary crate named `keepy-uppy` that compiles and exits immediately. Later tasks add `mod` declarations to `main.rs` and replace its body.

- [ ] **Step 1: Create `Cargo.toml`**

```toml
[package]
name = "keepy-uppy"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "keepy-uppy"
path = "src/main.rs"

[dependencies]
objc2 = "0.6.4"

[dependencies.objc2-foundation]
version = "0.3.2"
features = ["NSString", "NSNotification", "NSError"]

[dependencies.objc2-app-kit]
version = "0.3.2"
features = [
    "NSApplication",
    "NSResponder",
]

[dependencies.objc2-service-management]
version = "0.3.2"
```

- [ ] **Step 2: Create `src/main.rs`**

```rust
fn main() {}
```

- [ ] **Step 3: Verify it compiles**

Run: `cargo build`
Expected: `Compiling keepy-uppy v0.1.0 (...)` then `Finished` with no errors.

- [ ] **Step 4: Commit**

```bash
git add Cargo.toml Cargo.lock src/main.rs
git commit -m "Scaffold keepy-uppy binary crate"
```

---

### Task 2: `power.rs` — sleep-state parsing

**Files:**
- Create: `src/power.rs`
- Modify: `src/main.rs` (add `mod power;`)
- Test: inline `#[cfg(test)] mod tests` in `src/power.rs`

**Interfaces:**
- Produces: `pub enum SleepState { Disabled, Enabled, Unknown }` (derives `Debug, Clone, Copy, PartialEq, Eq`), `pub fn parse_sleep_disabled(output: &str) -> SleepState`.

- [ ] **Step 1: Write the failing tests**

Create `src/power.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SleepState {
    Disabled,
    Enabled,
    Unknown,
}

pub fn parse_sleep_disabled(output: &str) -> SleepState {
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DISABLED_OUTPUT: &str = "\
System-wide power settings:
 SleepDisabled      1
Currently in use:
 standbydelaylow      10
 standbydelayhigh     10
 highstandbythreshold 50
 womp                 1
 networkoversleep     0
 disksleep             10
 sleep                 1
 hibernatefile         /var/vm/sleepimage
 autopoweroffdelay     14400
 powernap              1
 gpuswitch             2
 hibernatemode         3
 ttyskeepawake         1
 displaysleep          10
 tcpkeepalive          1
 lowpowermode          0
 acwake                 0
 lidwake               1
";

    const DEFAULT_OUTPUT: &str = "\
Currently in use:
 standbydelaylow      10
 standbydelayhigh     10
 highstandbythreshold 50
 womp                 1
 networkoversleep     0
 disksleep             10
 sleep                 10
 hibernatefile         /var/vm/sleepimage
 autopoweroffdelay     14400
 powernap              1
 gpuswitch             2
 hibernatemode         3
 ttyskeepawake         1
 displaysleep          10
 tcpkeepalive          1
 lowpowermode          0
 acwake                 0
 lidwake               1
";

    const MALFORMED_OUTPUT: &str = "\
System-wide power settings:
 SleepDisabled      maybe
Currently in use:
 sleep                 10
";

    #[test]
    fn parses_disabled_state() {
        assert_eq!(parse_sleep_disabled(DISABLED_OUTPUT), SleepState::Disabled);
    }

    #[test]
    fn defaults_to_enabled_when_line_absent() {
        assert_eq!(parse_sleep_disabled(DEFAULT_OUTPUT), SleepState::Enabled);
    }

    #[test]
    fn unknown_state_on_unexpected_value() {
        assert_eq!(parse_sleep_disabled(MALFORMED_OUTPUT), SleepState::Unknown);
    }
}
```

Add to `src/main.rs`:

```rust
mod power;

fn main() {}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test parse_sleep_disabled`
Expected: compile error or panic from `todo!()` — the tests do not pass yet.

- [ ] **Step 3: Implement `parse_sleep_disabled`**

Replace the `todo!()` body in `src/power.rs`:

```rust
pub fn parse_sleep_disabled(output: &str) -> SleepState {
    for line in output.lines() {
        let mut parts = line.split_whitespace();
        if parts.next() == Some("SleepDisabled") {
            return match parts.next() {
                Some("1") => SleepState::Disabled,
                Some("0") => SleepState::Enabled,
                _ => SleepState::Unknown,
            };
        }
    }
    SleepState::Enabled
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test parse_sleep_disabled`
Expected: `test result: ok. 3 passed`

- [ ] **Step 5: Commit**

```bash
git add src/power.rs src/main.rs
git commit -m "Add pmset SleepDisabled parsing"
```

---

### Task 3: `power.rs` — battery parsing

**Files:**
- Modify: `src/power.rs`

**Interfaces:**
- Consumes: nothing from Task 2 (independent addition to the same file).
- Produces: `pub enum PowerSource { Battery, ACPower, Unknown }`, `pub struct BatteryState { pub percentage: Option<u8>, pub source: PowerSource }` (both derive `Debug, Clone, Copy, PartialEq, Eq`), `pub fn parse_battery(output: &str) -> BatteryState`.

- [ ] **Step 1: Write the failing tests**

Add to `src/power.rs` (above the existing `#[cfg(test)] mod tests` block):

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerSource {
    Battery,
    ACPower,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BatteryState {
    pub percentage: Option<u8>,
    pub source: PowerSource,
}

pub fn parse_battery(output: &str) -> BatteryState {
    todo!()
}
```

Add to the `tests` module in `src/power.rs`:

```rust
    const BATTERY_DISCHARGING: &str = "\
Now drawing from 'Battery Power'
 -InternalBattery-0 (id=4325027)\t87%; discharging; 3:48 remaining present: true
";

    const AC_CHARGED: &str = "\
Now drawing from 'AC Power'
 -InternalBattery-0 (id=4325027)\t100%; charged; 0:00 remaining present: true
";

    const AC_NO_BATTERY: &str = "\
Now drawing from 'AC Power'
";

    #[test]
    fn parses_discharging_battery() {
        let state = parse_battery(BATTERY_DISCHARGING);
        assert_eq!(state.source, PowerSource::Battery);
        assert_eq!(state.percentage, Some(87));
    }

    #[test]
    fn parses_charged_on_ac() {
        let state = parse_battery(AC_CHARGED);
        assert_eq!(state.source, PowerSource::ACPower);
        assert_eq!(state.percentage, Some(100));
    }

    #[test]
    fn desktop_mac_has_no_percentage() {
        let state = parse_battery(AC_NO_BATTERY);
        assert_eq!(state.source, PowerSource::ACPower);
        assert_eq!(state.percentage, None);
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cargo test parse_battery`
Expected: compile error or panic from `todo!()`.

- [ ] **Step 3: Implement `parse_battery`**

Replace the `todo!()` body:

```rust
pub fn parse_battery(output: &str) -> BatteryState {
    let source = if output.contains("'Battery Power'") {
        PowerSource::Battery
    } else if output.contains("'AC Power'") {
        PowerSource::ACPower
    } else {
        PowerSource::Unknown
    };

    let percentage = output.lines().find_map(|line| {
        let percent_idx = line.find('%')?;
        let digits_start = line[..percent_idx]
            .rfind(|c: char| !c.is_ascii_digit())
            .map(|i| i + 1)
            .unwrap_or(0);
        line[digits_start..percent_idx].parse::<u8>().ok()
    });

    BatteryState { percentage, source }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cargo test parse_battery`
Expected: `test result: ok. 3 passed`

- [ ] **Step 5: Commit**

```bash
git add src/power.rs
git commit -m "Add pmset battery-state parsing"
```

---

### Task 4: `power.rs` — system calls (read/set state)

**Files:**
- Modify: `src/power.rs`

**Interfaces:**
- Consumes: `SleepState`, `BatteryState`, `parse_sleep_disabled`, `parse_battery` (Tasks 2-3).
- Produces: `pub enum PowerError { CommandFailed(std::io::Error), NonZeroExit(String), Utf8(std::string::FromUtf8Error) }` (derives `Debug`) with `pub fn is_user_cancelled(&self) -> bool`; `pub fn read_sleep_state() -> Result<SleepState, PowerError>`; `pub fn read_battery_state() -> Result<BatteryState, PowerError>`; `pub fn set_sleep_disabled(disabled: bool) -> Result<(), PowerError>`.

These functions call real system processes, so they are not unit-tested — verified by `cargo build` here, and exercised for real in Task 7's manual toggle test.

- [ ] **Step 1: Add `PowerError` and the three functions**

Add to the top of `src/power.rs`:

```rust
use std::process::Command;
```

Add below the existing parsing functions (still above the `#[cfg(test)]` module):

```rust
#[derive(Debug)]
pub enum PowerError {
    CommandFailed(std::io::Error),
    NonZeroExit(String),
    Utf8(std::string::FromUtf8Error),
}

impl PowerError {
    // osascript's exact error text when the user dismisses the admin-auth
    // dialog is "User canceled. (-128)" — this is the only reliable way to
    // distinguish a deliberate cancel from a real failure.
    pub fn is_user_cancelled(&self) -> bool {
        matches!(self, PowerError::NonZeroExit(msg) if msg.contains("User canceled"))
    }
}

pub fn read_sleep_state() -> Result<SleepState, PowerError> {
    let output = Command::new("pmset")
        .arg("-g")
        .output()
        .map_err(PowerError::CommandFailed)?;
    let stdout = String::from_utf8(output.stdout).map_err(PowerError::Utf8)?;
    Ok(parse_sleep_disabled(&stdout))
}

pub fn read_battery_state() -> Result<BatteryState, PowerError> {
    let output = Command::new("pmset")
        .args(["-g", "batt"])
        .output()
        .map_err(PowerError::CommandFailed)?;
    let stdout = String::from_utf8(output.stdout).map_err(PowerError::Utf8)?;
    Ok(parse_battery(&stdout))
}

pub fn set_sleep_disabled(disabled: bool) -> Result<(), PowerError> {
    let flag = if disabled { "1" } else { "0" };
    let script =
        format!("do shell script \"pmset -a disablesleep {flag}\" with administrator privileges");
    let output = Command::new("osascript")
        .args(["-e", &script])
        .output()
        .map_err(PowerError::CommandFailed)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(PowerError::NonZeroExit(
            String::from_utf8_lossy(&output.stderr).into_owned(),
        ))
    }
}
```

- [ ] **Step 2: Verify it compiles and existing tests still pass**

Run: `cargo test`
Expected: all 6 existing tests still `ok`, no compile errors.

- [ ] **Step 3: Manually verify `read_sleep_state` against the real system**

Run: `cargo run` — this currently just calls `fn main() {}`, so instead run a one-off check:
`cargo build && ./target/debug/keepy-uppy` (should do nothing, exit 0) — then separately confirm the function logic against reality by running `pmset -g | grep -i sleepdisabled` in a terminal and comparing to what you'd expect `parse_sleep_disabled` to return for that exact output. This is the last point where power.rs is checked against the real system before it's wired into the UI in Task 7.

- [ ] **Step 4: Commit**

```bash
git add src/power.rs
git commit -m "Add pmset read/write system calls via osascript admin prompt"
```

---

### Task 5: `login_item.rs` — SMAppService wrapper

**Files:**
- Create: `src/login_item.rs`
- Modify: `src/main.rs` (add `mod login_item;`)
- Modify: `Cargo.toml` (no new features needed — `objc2-service-management` exposes `SMAppService` without feature-gating)

**Interfaces:**
- Produces: `pub enum LoginItemStatus { NotRegistered, Enabled, RequiresApproval, NotFound }` (derives `Debug, Clone, Copy, PartialEq, Eq`); `pub fn status() -> LoginItemStatus`; `pub fn register() -> Result<(), objc2::rc::Retained<objc2_foundation::NSError>>`; `pub fn unregister() -> Result<(), objc2::rc::Retained<objc2_foundation::NSError>>`.

This wraps a real macOS system service (register actually adds/removes a login item) so it's not unit-tested — verified by `cargo build` here, exercised for real in Task 7's manual "Launch at Login" test.

- [ ] **Step 1: Create `src/login_item.rs`**

```rust
use objc2::rc::Retained;
use objc2_foundation::NSError;
use objc2_service_management::{SMAppService, SMAppServiceStatus};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginItemStatus {
    NotRegistered,
    Enabled,
    RequiresApproval,
    NotFound,
}

fn service() -> Retained<SMAppService> {
    unsafe { SMAppService::mainAppService() }
}

pub fn status() -> LoginItemStatus {
    let raw = unsafe { service().status() };
    if raw == SMAppServiceStatus::NotRegistered {
        LoginItemStatus::NotRegistered
    } else if raw == SMAppServiceStatus::Enabled {
        LoginItemStatus::Enabled
    } else if raw == SMAppServiceStatus::RequiresApproval {
        LoginItemStatus::RequiresApproval
    } else {
        LoginItemStatus::NotFound
    }
}

pub fn register() -> Result<(), Retained<NSError>> {
    unsafe { service().registerAndReturnError() }
}

pub fn unregister() -> Result<(), Retained<NSError>> {
    unsafe { service().unregisterAndReturnError() }
}
```

Add to `src/main.rs`:

```rust
mod login_item;
mod power;

fn main() {}
```

- [ ] **Step 2: Verify it compiles**

Run: `cargo build`
Expected: `Finished` with no errors. If it fails on an unresolved `SMAppServiceStatus` variant comparison, check that `SMAppServiceStatus` implements `PartialEq` in `objc2-service-management` 0.3.2 — if it doesn't, compare the underlying integer field directly instead (per the research note, it's a bindgen newtype wrapping an integer).

- [ ] **Step 3: Commit**

```bash
git add src/login_item.rs src/main.rs
git commit -m "Add SMAppService login-item wrapper"
```

---

### Task 6: AppDelegate skeleton — status item with icon

**Files:**
- Create: `src/app_delegate.rs`
- Modify: `src/main.rs` (replace body with full `NSApplication` wiring)
- Modify: `Cargo.toml` (add AppKit/Foundation features for this task)

**Interfaces:**
- Consumes: nothing yet from `power.rs`/`login_item.rs` (wired in Task 7).
- Produces: `pub struct AppDelegate` with `pub fn new(mtm: MainThreadMarker) -> Retained<Self>`. This is the type Tasks 7-9 extend.

This is a visual smoke test — no automated test is possible. Success is "run the binary, see a balloon icon appear in the menu bar."

- [ ] **Step 1: Add required Cargo features**

Edit `Cargo.toml`, replace the `objc2-foundation` and `objc2-app-kit` blocks:

```toml
[dependencies.objc2-foundation]
version = "0.3.2"
features = ["NSString", "NSNotification", "NSError"]

[dependencies.objc2-app-kit]
version = "0.3.2"
features = [
    "NSApplication",
    "NSResponder",
    "NSStatusBar",
    "NSStatusItem",
    "NSStatusBarButton",
    "NSButton",
    "NSControl",
    "NSImage",
]
```

- [ ] **Step 2: Create `src/app_delegate.rs`**

```rust
use std::cell::OnceCell;

use objc2::rc::Retained;
use objc2::runtime::NSObject;
use objc2::{define_class, msg_send, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplicationDelegate, NSImage, NSStatusBar, NSStatusBarButton, NSStatusItem,
    NSVariableStatusItemLength,
};
use objc2_foundation::{NSNotification, NSObjectProtocol, NSString};

struct Ivars {
    status_item: OnceCell<Retained<NSStatusItem>>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[ivars = Ivars]
    pub struct AppDelegate;

    unsafe impl NSObjectProtocol for AppDelegate {}

    unsafe impl NSApplicationDelegate for AppDelegate {
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn did_finish_launching(&self, _notification: &NSNotification) {
            self.setup_status_item();
        }
    }
);

impl AppDelegate {
    pub fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(Ivars {
            status_item: OnceCell::new(),
        });
        unsafe { msg_send![super(this), init] }
    }

    fn setup_status_item(&self) {
        let mtm = MainThreadMarker::from(self);
        let status_bar = NSStatusBar::systemStatusBar();
        let item = status_bar.statusItemWithLength(NSVariableStatusItemLength);

        if let Some(button) = item.button(mtm) {
            self.render_icon(&button, false);
        }

        let _ = self.ivars().status_item.set(item);
    }

    fn render_icon(&self, button: &NSStatusBarButton, keeping_awake: bool) {
        let symbol_name = if keeping_awake { "balloon.fill" } else { "balloon" };
        let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str(symbol_name),
            Some(&NSString::from_str("Keepy Uppy")),
        );
        button.setImage(image.as_deref());
    }
}
```

- [ ] **Step 3: Wire it up in `src/main.rs`**

Replace the full contents of `src/main.rs`:

```rust
mod app_delegate;
mod login_item;
mod power;

use app_delegate::AppDelegate;
use objc2::runtime::ProtocolObject;
use objc2::MainThreadMarker;
use objc2_app_kit::NSApplication;

fn main() {
    let mtm = MainThreadMarker::new().expect("keepy-uppy must start on the main thread");
    let app = NSApplication::sharedApplication(mtm);

    let delegate = AppDelegate::new(mtm);
    let protocol_delegate = ProtocolObject::from_ref(&*delegate);
    app.setDelegate(Some(protocol_delegate));

    app.run();
}
```

- [ ] **Step 4: Build and run the smoke test**

Run: `cargo build`
Expected: `Finished` with no errors. If a type is unresolved, add its name as a feature per the Global Constraints note.

Run: `cargo run`
Expected: no crash; a balloon-outline icon appears in the menu bar. Quit via Activity Monitor or `killall keepy-uppy` (no Quit menu item exists yet — that's Task 7).

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml src/app_delegate.rs src/main.rs
git commit -m "Add AppDelegate skeleton with status bar icon"
```

---

### Task 7: Menu construction, click routing, toggle/login-item wiring

**Files:**
- Modify: `src/app_delegate.rs`
- Modify: `Cargo.toml` (add `NSMenu`, `NSMenuItem`, `NSEvent`, `NSView` features)

**Interfaces:**
- Consumes: `power::{SleepState, read_sleep_state, set_sleep_disabled, PowerError}` (Task 4), `login_item::{LoginItemStatus, status, register, unregister}` (Task 5).
- Produces: a fully interactive menu bar item — left-click toggles directly, right-click shows a menu with live state, a Toggle item, a Launch at Login checkbox, and Quit.

This is the largest single deliverable in the plan and the one exercising the two riskiest API patterns flagged in Global Constraints (custom inherent selectors, `AnyObject` coercion). Verified by `cargo build` plus a manual click-through — no automated test is possible for AppKit event handling.

- [ ] **Step 1: Add required Cargo features**

Edit `Cargo.toml`'s `objc2-app-kit` features list, add `"NSMenu", "NSMenuItem", "NSEvent", "NSView"`:

```toml
[dependencies.objc2-app-kit]
version = "0.3.2"
features = [
    "NSApplication",
    "NSResponder",
    "NSStatusBar",
    "NSStatusItem",
    "NSStatusBarButton",
    "NSButton",
    "NSControl",
    "NSImage",
    "NSMenu",
    "NSMenuItem",
    "NSEvent",
    "NSView",
]
```

- [ ] **Step 2: Expand the imports and `Ivars` struct**

Replace the top of `src/app_delegate.rs` (imports and `Ivars`):

```rust
use std::cell::OnceCell;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, NSObject, Sel};
use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSApplication, NSApplicationDelegate, NSControlStateValue, NSEventMask, NSEventType, NSImage,
    NSMenu, NSMenuItem, NSStatusBar, NSStatusBarButton, NSStatusItem, NSVariableStatusItemLength,
};
use objc2_foundation::{NSNotification, NSObjectProtocol, NSString};

use crate::{login_item, power};

struct Ivars {
    status_item: OnceCell<Retained<NSStatusItem>>,
    menu: OnceCell<Retained<NSMenu>>,
    status_label: OnceCell<Retained<NSMenuItem>>,
    toggle_item: OnceCell<Retained<NSMenuItem>>,
    login_item_entry: OnceCell<Retained<NSMenuItem>>,
}
```

Update `AppDelegate::new` to initialize the new fields:

```rust
impl AppDelegate {
    pub fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(Ivars {
            status_item: OnceCell::new(),
            menu: OnceCell::new(),
            status_label: OnceCell::new(),
            toggle_item: OnceCell::new(),
            login_item_entry: OnceCell::new(),
        });
        unsafe { msg_send![super(this), init] }
    }
```

- [ ] **Step 3: Wire the button's target/action and build the menu in `setup_status_item`**

Replace `setup_status_item` and `render_icon`:

```rust
    fn setup_status_item(&self) {
        let mtm = MainThreadMarker::from(self);
        let status_bar = NSStatusBar::systemStatusBar();
        let item = status_bar.statusItemWithLength(NSVariableStatusItemLength);

        if let Some(button) = item.button(mtm) {
            self.render_icon(&button, false);
            let target: &AnyObject = self;
            unsafe {
                button.setTarget(Some(target));
                button.setAction(Some(sel!(statusItemClicked:)));
            }
            button.sendActionOn(NSEventMask::LeftMouseUp | NSEventMask::RightMouseUp);
        }

        let menu = self.build_menu(mtm);
        let _ = self.ivars().menu.set(menu);
        let _ = self.ivars().status_item.set(item);
        self.refresh_menu_state(mtm);
    }

    fn render_icon(&self, button: &NSStatusBarButton, keeping_awake: bool) {
        let symbol_name = if keeping_awake { "balloon.fill" } else { "balloon" };
        let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str(symbol_name),
            Some(&NSString::from_str("Keepy Uppy")),
        );
        button.setImage(image.as_deref());
    }
```

- [ ] **Step 4: Add menu-building helpers**

Add to the `impl AppDelegate` block:

```rust
    fn make_item(&self, mtm: MainThreadMarker, title: &str, action: Sel) -> Retained<NSMenuItem> {
        let item = unsafe {
            NSMenuItem::initWithTitle_action_keyEquivalent(
                NSMenuItem::alloc(mtm),
                &NSString::from_str(title),
                Some(action),
                &NSString::from_str(""),
            )
        };
        let target: &AnyObject = self;
        unsafe { item.setTarget(Some(target)) };
        item
    }

    fn make_label(&self, mtm: MainThreadMarker, title: &str) -> Retained<NSMenuItem> {
        let item = unsafe {
            NSMenuItem::initWithTitle_action_keyEquivalent(
                NSMenuItem::alloc(mtm),
                &NSString::from_str(title),
                None,
                &NSString::from_str(""),
            )
        };
        item.setEnabled(false);
        item
    }

    fn build_menu(&self, mtm: MainThreadMarker) -> Retained<NSMenu> {
        let menu = NSMenu::new(mtm);

        let status_label = self.make_label(mtm, "Status: Normal Sleep");
        menu.addItem(&status_label);

        menu.addItem(&NSMenuItem::separatorItem(mtm));

        let toggle_item = self.make_item(mtm, "Turn On Keepy Uppy", sel!(toggleClicked:));
        menu.addItem(&toggle_item);

        let login_item = self.make_item(mtm, "Launch at Login", sel!(loginItemClicked:));
        menu.addItem(&login_item);

        menu.addItem(&NSMenuItem::separatorItem(mtm));

        let quit_item = self.make_item(mtm, "Quit Keepy Uppy", sel!(quitClicked:));
        menu.addItem(&quit_item);

        let _ = self.ivars().status_label.set(status_label);
        let _ = self.ivars().toggle_item.set(toggle_item);
        let _ = self.ivars().login_item_entry.set(login_item);

        menu
    }

    fn refresh_menu_state(&self, mtm: MainThreadMarker) {
        let sleep_state = power::read_sleep_state().unwrap_or(power::SleepState::Unknown);
        let keeping_awake = sleep_state == power::SleepState::Disabled;

        if let Some(status_label) = self.ivars().status_label.get() {
            let text = match sleep_state {
                power::SleepState::Disabled => "Status: Keeping Awake",
                power::SleepState::Enabled => "Status: Normal Sleep",
                power::SleepState::Unknown => "Status: Unknown",
            };
            status_label.setTitle(&NSString::from_str(text));
        }

        if let Some(toggle_item) = self.ivars().toggle_item.get() {
            let text = if keeping_awake {
                "Turn Off Keepy Uppy"
            } else {
                "Turn On Keepy Uppy"
            };
            toggle_item.setTitle(&NSString::from_str(text));
        }

        if let Some(login_item) = self.ivars().login_item_entry.get() {
            let is_enabled = login_item::status() == login_item::LoginItemStatus::Enabled;
            login_item.setState(if is_enabled {
                NSControlStateValue::On
            } else {
                NSControlStateValue::Off
            });
        }

        if let Some(status_item) = self.ivars().status_item.get() {
            if let Some(button) = status_item.button(mtm) {
                self.render_icon(&button, keeping_awake);
            }
        }
    }
```

- [ ] **Step 5: Add click routing and action handlers**

Add to the `impl AppDelegate` block:

```rust
    fn handle_status_item_click(&self) {
        let mtm = MainThreadMarker::from(self);
        let Some(status_item) = self.ivars().status_item.get() else {
            return;
        };
        let Some(button) = status_item.button(mtm) else {
            return;
        };
        let app = NSApplication::sharedApplication(mtm);
        let Some(event) = app.currentEvent() else {
            return;
        };

        if event.r#type() == NSEventType::RightMouseUp {
            self.refresh_menu_state(mtm);
            if let Some(menu) = self.ivars().menu.get() {
                NSMenu::popUpContextMenu_withEvent_forView_withFont(menu, &event, &button, None);
            }
        } else {
            self.perform_toggle();
        }
    }

    fn perform_toggle(&self) {
        let mtm = MainThreadMarker::from(self);
        let currently_disabled = power::read_sleep_state().unwrap_or(power::SleepState::Unknown)
            == power::SleepState::Disabled;

        // A cancel is a deliberate, silent no-op by design (spec §3) — no UI.
        // Any other failure has no dialog framework to surface through yet,
        // so it stays silent too, but is at least visible in the console for
        // debugging rather than vanishing entirely.
        if let Err(err) = power::set_sleep_disabled(!currently_disabled) {
            if !err.is_user_cancelled() {
                eprintln!("keepy-uppy: failed to toggle sleep state: {err:?}");
            }
        }

        self.refresh_menu_state(mtm);
    }

    fn toggle_login_item(&self) {
        let currently_enabled = login_item::status() == login_item::LoginItemStatus::Enabled;
        let _ = if currently_enabled {
            login_item::unregister()
        } else {
            login_item::register()
        };

        let mtm = MainThreadMarker::from(self);
        self.refresh_menu_state(mtm);
    }

    fn perform_quit(&self) {
        let mtm = MainThreadMarker::from(self);
        NSApplication::sharedApplication(mtm).terminate(None);
    }
```

- [ ] **Step 6: Expose the custom selectors**

Add a third block inside the `define_class!` macro invocation (after the existing `unsafe impl NSApplicationDelegate for AppDelegate { ... }` block, still before the closing `);`):

```rust
    impl AppDelegate {
        #[unsafe(method(statusItemClicked:))]
        fn status_item_clicked(&self, _sender: Option<&AnyObject>) {
            self.handle_status_item_click();
        }

        #[unsafe(method(toggleClicked:))]
        fn toggle_clicked(&self, _sender: Option<&AnyObject>) {
            self.perform_toggle();
        }

        #[unsafe(method(loginItemClicked:))]
        fn login_item_clicked(&self, _sender: Option<&AnyObject>) {
            self.toggle_login_item();
        }

        #[unsafe(method(quitClicked:))]
        fn quit_clicked(&self, _sender: Option<&AnyObject>) {
            self.perform_quit();
        }
    }
```

- [ ] **Step 7: Build and manually test**

Run: `cargo build`
Expected: `Finished` with no errors. If this specific block fails to compile, see Global Constraints risk item 1 — consult `docs.rs/objc2/0.6.4`'s `define_class!` documentation for the current syntax to expose non-protocol selectors.

Run: `cargo run`, then manually verify:
1. Right-click the balloon icon → menu appears showing "Status: Normal Sleep", "Turn On Keepy Uppy", "Launch at Login" (unchecked), "Quit Keepy Uppy".
2. Click "Turn On Keepy Uppy" → macOS admin prompt appears → enter password → menu item now reads "Turn Off Keepy Uppy", icon becomes a filled balloon. Confirm with `pmset -g | grep SleepDisabled` in a terminal — should show `1`.
3. Left-click the icon directly (menu closed) → admin prompt appears again → toggles back off, icon returns to outline. Confirm `pmset -g | grep SleepDisabled` shows `0` or is absent.
4. Click "Launch at Login" → no prompt (SMAppService doesn't need one) → checkbox becomes checked. Verify in System Settings → General → Login Items that "Keepy Uppy" appears (note: SMAppService login items sometimes only fully register from within a proper `.app` bundle — if this doesn't show up running via `cargo run`, defer full verification to Task 10's packaged build).
5. Cancel the admin dialog on a toggle attempt → confirm no crash and no error dialog appears (silent no-op).
6. Click "Quit Keepy Uppy" → app exits cleanly, icon disappears from menu bar.

- [ ] **Step 8: Commit**

```bash
git add Cargo.toml src/app_delegate.rs
git commit -m "Add menu, click routing, and toggle/login-item wiring"
```

---

### Task 8: External sync timer and low-battery auto-off

**Files:**
- Modify: `src/app_delegate.rs`
- Modify: `Cargo.toml` (add `NSDate`, `NSTimer`, `NSUserNotification` features)

**Interfaces:**
- Consumes: `power::{read_battery_state, read_sleep_state, set_sleep_disabled, SleepState, PowerSource}` (Task 4), `AppDelegate::refresh_menu_state` (Task 7).
- Produces: a 30-second repeating sync that (a) keeps the icon/menu accurate if `pmset` state changes externally, and (b) re-enables sleep and posts a notification if battery drops below 10% on battery power while sleep is disabled.

Not unit-testable (timer + live system state). Verified by `cargo build` and a manual test using a lowered threshold.

- [ ] **Step 1: Add required Cargo features**

Edit `Cargo.toml`:

```toml
[dependencies.objc2-foundation]
version = "0.3.2"
features = ["NSString", "NSNotification", "NSError", "NSDate", "NSTimer", "NSUserNotification"]
```

- [ ] **Step 2: Add the timer import and battery threshold constant**

Add to the imports in `src/app_delegate.rs`:

```rust
use objc2_foundation::{NSNotification, NSObjectProtocol, NSString, NSTimer, NSUserNotification, NSUserNotificationCenter};
```

Add near the top of the file, after the imports:

```rust
const SYNC_INTERVAL_SECONDS: f64 = 30.0;
const LOW_BATTERY_THRESHOLD: u8 = 10;
```

- [ ] **Step 3: Start the timer when the app launches**

Update `did_finish_launching` inside `define_class!`'s `NSApplicationDelegate` impl block:

```rust
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn did_finish_launching(&self, _notification: &NSNotification) {
            self.setup_status_item();
            self.start_sync_timer();
        }
```

- [ ] **Step 4: Add the timer-scheduling and sync/auto-off logic**

Add to the `impl AppDelegate` block:

```rust
    fn start_sync_timer(&self) {
        let target: &AnyObject = self;
        let _timer = unsafe {
            NSTimer::scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
                SYNC_INTERVAL_SECONDS,
                target,
                sel!(timerFired:),
                None,
                true,
            )
        };
    }

    fn sync_from_system(&self) {
        let mtm = MainThreadMarker::from(self);
        self.refresh_menu_state(mtm);
        self.check_low_battery_auto_off();
    }

    fn check_low_battery_auto_off(&self) {
        let Ok(battery) = power::read_battery_state() else {
            return;
        };
        let Ok(sleep_state) = power::read_sleep_state() else {
            return;
        };

        let on_battery = battery.source == power::PowerSource::Battery;
        let low = battery.percentage.map_or(false, |p| p < LOW_BATTERY_THRESHOLD);

        if on_battery && low && sleep_state == power::SleepState::Disabled {
            let _ = power::set_sleep_disabled(false);
            self.post_low_battery_notification();
            self.refresh_menu_state(MainThreadMarker::from(self));
        }
    }

    fn post_low_battery_notification(&self) {
        let notification = NSUserNotification::new();
        notification.setTitle(Some(&NSString::from_str("Keepy Uppy")));
        notification.setInformativeText(Some(&NSString::from_str(
            "Battery below 10% — sleep re-enabled automatically.",
        )));
        NSUserNotificationCenter::defaultUserNotificationCenter()
            .deliverNotification(&notification);
    }
```

- [ ] **Step 5: Expose the timer's selector**

Add to the inherent `impl AppDelegate` block inside `define_class!` (from Task 7 Step 6):

```rust
        #[unsafe(method(timerFired:))]
        fn timer_fired(&self, _timer: Option<&NSTimer>) {
            self.sync_from_system();
        }
```

- [ ] **Step 6: Build and manually test**

Run: `cargo build`
Expected: `Finished` with no errors. If `NSUserNotification`/`NSUserNotificationCenter` don't resolve, see Global Constraints risk item 3 — check `docs.rs/objc2-foundation/0.3.2` for the current method names (`new`, `setTitle`, `setInformativeText`, `defaultUserNotificationCenter`, `deliverNotification` are the ones to look for).

Manual test — external sync: `cargo run`, then in a separate terminal run `sudo pmset -a disablesleep 1`. Within 30 seconds the menu bar icon should switch to filled without any click. Run `sudo pmset -a disablesleep 0` and confirm it reverts within 30 seconds.

Manual test — low-battery auto-off (temporarily lower the threshold to make this practical): change `LOW_BATTERY_THRESHOLD` to a value just above your current battery percentage while unplugged, `cargo run`, toggle Keepy Uppy on, unplug if not already, and confirm within 30 seconds sleep is re-enabled and a notification banner appears. Revert the constant back to `10` afterward.

- [ ] **Step 7: Commit**

```bash
git add Cargo.toml src/app_delegate.rs
git commit -m "Add 30s external-state sync and low-battery auto-off"
```

---

### Task 9: Quit handling — restore sleep on termination

**Files:**
- Modify: `src/app_delegate.rs`

**Interfaces:**
- Consumes: `power::{read_sleep_state, set_sleep_disabled, SleepState}` (Task 4).
- Produces: sleep is re-enabled automatically whenever the app quits while it was disabled (spec §3).

- [ ] **Step 1: Add the termination handler**

Add to the `NSApplicationDelegate` impl block inside `define_class!`:

```rust
        #[unsafe(method(applicationWillTerminate:))]
        fn will_terminate(&self, _notification: &NSNotification) {
            self.restore_sleep_on_quit();
        }
```

Add to the `impl AppDelegate` block:

```rust
    fn restore_sleep_on_quit(&self) {
        let disabled = power::read_sleep_state().unwrap_or(power::SleepState::Unknown)
            == power::SleepState::Disabled;
        if disabled {
            let _ = power::set_sleep_disabled(false);
        }
    }
```

- [ ] **Step 2: Build and manually test**

Run: `cargo build`
Expected: `Finished` with no errors.

Manual test: `cargo run`, toggle Keepy Uppy on (confirm `pmset -g | grep SleepDisabled` shows `1`), click "Quit Keepy Uppy". An admin prompt should appear one final time; approve it, then confirm `pmset -g | grep SleepDisabled` shows `0` or is absent.

- [ ] **Step 3: Commit**

```bash
git add src/app_delegate.rs
git commit -m "Restore sleep on quit if it was disabled"
```

---

### Task 10: Packaging — icon, Info.plist, app bundle build

**Files:**
- Create: `packaging/generate_icon.swift`
- Create: `packaging/Info.plist`
- Create: `justfile`

**Interfaces:**
- Produces: `packaging/AppIcon.icns` (generated artifact, committed once), `Keepy Uppy.app` assembled at `target/bundle/Keepy Uppy.app` via `just bundle`.

- [ ] **Step 1: Create the icon-generation script**

```swift
import AppKit

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outputDir = "packaging/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

guard let symbol = NSImage(systemSymbolName: "balloon.fill", accessibilityDescription: nil) else {
    fatalError("balloon.fill symbol not found")
}

for (size, name) in sizes {
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.8, weight: .regular)
    guard let configured = symbol.withSymbolConfiguration(config) else { continue }

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    configured.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()

    let pngData = rep.representation(using: .png, properties: [:])!
    try! pngData.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}

print("Wrote iconset to \(outputDir)")
```

- [ ] **Step 2: Create `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Keepy Uppy</string>
    <key>CFBundleDisplayName</key>
    <string>Keepy Uppy</string>
    <key>CFBundleIdentifier</key>
    <string>au.com.workwireless.keepy-uppy</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>keepy-uppy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Keepy Uppy</string>
</dict>
</plist>
```

- [ ] **Step 3: Create the `justfile` with icon and bundle targets**

```just
app_name := "Keepy Uppy"
bin_name := "keepy-uppy"
build_dir := "target/bundle"

icon:
    swift packaging/generate_icon.swift
    iconutil -c icns packaging/AppIcon.iconset -o packaging/AppIcon.icns
    rm -rf packaging/AppIcon.iconset

build:
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
    cargo build --release --target aarch64-apple-darwin
    cargo build --release --target x86_64-apple-darwin

bundle: build
    rm -rf "{{build_dir}}/{{app_name}}.app"
    mkdir -p "{{build_dir}}/{{app_name}}.app/Contents/MacOS"
    mkdir -p "{{build_dir}}/{{app_name}}.app/Contents/Resources"
    lipo -create \
        "target/aarch64-apple-darwin/release/{{bin_name}}" \
        "target/x86_64-apple-darwin/release/{{bin_name}}" \
        -output "{{build_dir}}/{{app_name}}.app/Contents/MacOS/{{bin_name}}"
    cp packaging/Info.plist "{{build_dir}}/{{app_name}}.app/Contents/Info.plist"
    cp packaging/AppIcon.icns "{{build_dir}}/{{app_name}}.app/Contents/Resources/AppIcon.icns"
```

- [ ] **Step 4: Generate the icon and verify the bundle builds**

Run: `just icon`
Expected: `packaging/AppIcon.icns` is created. The rendered symbol may appear as a flat black/template-colored glyph rather than a tinted balloon — acceptable for a v1 placeholder icon; note this if it needs real art later.

Run: `just bundle`
Expected: `target/bundle/Keepy Uppy.app` exists with the universal binary, `Info.plist`, and `AppIcon.icns` in place.

Manual test: `open "target/bundle/Keepy Uppy.app"` — the app launches with no Dock icon (confirming `LSUIElement` took effect) and the balloon appears in the menu bar. Repeat the "Launch at Login" check from Task 7 Step 7 here — it should now register correctly from within a real bundle.

- [ ] **Step 5: Commit**

```bash
git add packaging/generate_icon.swift packaging/Info.plist packaging/AppIcon.icns justfile
git commit -m "Add icon generation and app bundle assembly"
```

---

### Task 11: Codesign, notarize, DMG, and README

**Files:**
- Modify: `justfile`
- Create: `README.md`

**Interfaces:**
- Produces: `just sign`, `just dmg`, `just notarize` targets; a `README.md` covering setup, build, the manual test checklist accumulated across Tasks 7-10, and the low-battery known limitation from spec §4.

- [ ] **Step 1: Add signing/notarization targets to the `justfile`**

Append to `justfile`:

```just
signing_identity := env_var("KEEPY_UPPY_SIGNING_IDENTITY")
notary_profile := env_var("KEEPY_UPPY_NOTARY_PROFILE")

sign: bundle
    codesign --force --deep --options runtime \
        --sign "{{signing_identity}}" \
        "{{build_dir}}/{{app_name}}.app"
    codesign --verify --deep --strict --verbose=2 "{{build_dir}}/{{app_name}}.app"

dmg: sign
    rm -f "{{build_dir}}/{{app_name}}.dmg"
    hdiutil create -volname "{{app_name}}" \
        -srcfolder "{{build_dir}}/{{app_name}}.app" \
        -ov -format UDZO \
        "{{build_dir}}/{{app_name}}.dmg"

notarize: dmg
    xcrun notarytool submit "{{build_dir}}/{{app_name}}.dmg" \
        --keychain-profile "{{notary_profile}}" \
        --wait
    xcrun stapler staple "{{build_dir}}/{{app_name}}.dmg"
```

- [ ] **Step 2: Verify the justfile parses**

Run: `just --list`
Expected: lists `icon`, `build`, `bundle`, `sign`, `dmg`, `notarize` with no parse errors.

- [ ] **Step 3: Write `README.md`**

```markdown
# Keepy Uppy

Keeps a MacBook awake with the lid closed by toggling `pmset -a disablesleep`
through a menu-bar balloon icon. See `docs/superpowers/specs/2026-08-06-keepy-uppy-design.md`
for the full design rationale.

## Prerequisites

- Xcode Command Line Tools (`xcode-select --install`)
- `rustup target add aarch64-apple-darwin x86_64-apple-darwin`
- [`just`](https://github.com/casey/just)
- A Developer ID Application certificate in your login keychain (for `just sign`)
- A notarytool keychain profile: `xcrun notarytool store-credentials` (for `just notarize`)

## Build and run (development)

    cargo run

## Build the distributable app

    just icon      # one-time, or after changing the icon
    just bundle     # unsigned .app in target/bundle/
    export KEEPY_UPPY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    export KEEPY_UPPY_NOTARY_PROFILE="your-notarytool-profile-name"
    just notarize   # signed, notarized, stapled .dmg in target/bundle/

## Manual test checklist

Run through this after any change to `app_delegate.rs`, `power.rs`, or `login_item.rs`:

- [ ] Right-click shows the menu with correct status label, toggle wording, and login-item checkbox state
- [ ] Toggling on prompts for admin password, icon fills in, `pmset -g | grep SleepDisabled` shows `1`
- [ ] Toggling off reverses all of the above
- [ ] Left-clicking the icon toggles directly without opening the menu
- [ ] Canceling the admin dialog is a silent no-op (no crash, no error dialog)
- [ ] "Launch at Login" registers/unregisters and is reflected in System Settings → General → Login Items
- [ ] External `sudo pmset -a disablesleep 1/0` is reflected in the icon within 30 seconds
- [ ] Low-battery auto-off re-enables sleep and posts a notification when tested with a lowered threshold
- [ ] Quitting while enabled re-enables sleep (one final admin prompt) before the app exits
- [ ] The packaged `.app` has no Dock icon and shows the balloon in the menu bar
- [ ] The packaged `.app` opens without warnings after signing + notarization

## Known limitation

Low-battery auto-off needs a password/Touch ID prompt to re-enable sleep, same
as every other state change (see spec §5's privilege model). If the lid is
closed and the Mac is unattended, that prompt has nobody to answer it, so
auto-off can't complete in exactly the scenario it exists for. It works
whenever the machine is attended. A future privileged-helper-daemon version
(SMAppService + XPC) would remove this gap — see spec §4 and §9.
```

- [ ] **Step 4: Commit**

```bash
git add justfile README.md
git commit -m "Add signing/notarization targets and README"
```
