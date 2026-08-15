import SwiftUI

/// What a session started from the menu holds awake: the lid axis, and the
/// disk axis directly beneath it.
///
/// **Why these two are together, and why they are not in General.** Plan 4 put
/// the wake-mode picker directly under "Default session" in General, arguing
/// that the two answer the same question about the same thing — what the menu's
/// "Keep awake…" rows will start; one says when it ends, the other how it holds
/// the Mac awake. Plan 6 then put the disk toggle directly beneath the picker on
/// exactly that argument: same question, same thing, one says how it holds the
/// Mac awake and the other whether it also holds attached disks out of idle.
/// That reasoning is still right and it is what this pane is made of — the pair
/// is one idea, in this order, and splitting it is the one arrangement Plan 6's
/// placement sentence forbids.
///
/// What changed is only the company they keep. Plan 7's tab map gives the
/// question "what does a session hold awake?" a tab of its own, so the pair
/// moved here whole rather than staying in a General tab that is otherwise
/// about the *app* — launching at login, and the background services. Safety &
/// Guards was never a candidate: it is about limits the daemon imposes on
/// sessions it did not start, including the CLI's, and these govern only
/// sessions started from the menu.
///
/// **The scope note travels with the picker, unchanged.** A tab called
/// "Display" invites the reading that this is machine-wide lid and screen
/// policy, which it is not; `wakeModeSettingsScopeNote` is the sentence that
/// says so, and it says the same thing here as it did in General.
struct DisplaySettingsTab: View {
    @AppStorage(DefaultWakeModePreference.key, store: PreferencesSuite.defaults)
    private var defaultWakeModeRaw: String = DefaultWakeModePreference.defaultRawValue
    @AppStorage(DefaultKeepDisksAwakePreference.key, store: PreferencesSuite.defaults)
    private var defaultKeepDisksAwake: Bool = DefaultKeepDisksAwakePreference.fallback
    @AppStorage(MenuBarIconStylePreference.key, store: PreferencesSuite.defaults)
    private var menuBarIconStyleRaw: String = MenuBarIconStylePreference.defaultRawValue

    private var defaultWakeMode: WakeMode {
        DefaultWakeModePreference.mode(rawValue: defaultWakeModeRaw)
    }

    var body: some View {
        Form {
            Section {
                SettingsPaneHeader(tab: .display)
            }

            // Its own Section rather than a second row of anything, so the
            // footer can change with the selection — the arrangement Safety's
            // thermal picker already uses: three short phrases can distinguish
            // the options but cannot explain what they cost.
            Section {
                // The literal used to live here. The Add-trigger sheet grew a
                // picker over the same three modes in Plan 8 Task 10, and two
                // controls selecting one thing under two labels is how a user
                // learns they are two settings.
                SettingsRow {
                    Picker(wakeModePickerTitle, selection: $defaultWakeModeRaw) {
                        ForEach(wakeModeSettingsOrder, id: \.self) { mode in
                            Text(wakeModeSettingsTitle(mode)).tag(mode.rawValue)
                        }
                    }
                } note: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(wakeModeSettingsExplanation(defaultWakeMode))
                            .settingsFootnote()
                        Text(wakeModeSettingsScopeNote)
                            .settingsFootnote()
                    }
                }
            }

            // Its own Section, for the reason the picker has one: the footer
            // has to carry both what this does and what it cannot do, and a
            // second row inside the picker's Section would put that sentence
            // under the wake-mode explanation, where it reads as a claim about
            // the modes.
            Section {
                SettingsRow {
                    Toggle(keepDisksAwakeSettingsTitle, isOn: $defaultKeepDisksAwake)
                } note: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(keepDisksAwakeSettingsFootnote)
                            .settingsFootnote()
                        Text(keepDisksAwakeSettingsScopeNote)
                            .settingsFootnote()
                    }
                }
            }

            // Last, and in its own Section, because it is the only thing on
            // this pane that changes nothing about what a session *does*. The
            // two above answer "what does a session hold awake"; this one is
            // about the menu bar, and putting it inside either of their
            // Sections would attach an appearance choice to a footer arguing
            // about power.
            Section {
                SettingsRow(menuBarIconSettingsFootnote) {
                    Picker(menuBarIconSettingsTitle, selection: $menuBarIconStyleRaw) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            Label(style.label, systemImage: style.symbol(active: true))
                                .tag(style.rawValue)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
