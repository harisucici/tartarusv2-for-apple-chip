# Tartarus V2 for Apple Silicon

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

**Tartarus Light 0.5.1** is a native macOS utility for the **Razer Tartarus V2** (`1532:022B`). It provides lighting controls and device-specific key remapping on Apple Silicon Macs. This is an independent project, not an official Razer product.

These READMEs are translated; the application interface is currently in Simplified Chinese. Chinese button labels below match the application.

## Features and requirements

- Solid color, lights off, built-in spectrum, and custom color cycling.
- Lighting changes are saved and applied automatically, including on launch and reconnection to the selected USB location.
- Custom cycling: 2–8 ordered colors, smooth transitions, 2–60 seconds per complete cycle.
- One source key can hold up to four target keys together, plus Command, Shift, Option and Control.
- Remapping is restricted to the selected Tartarus V2 keyboard interfaces. Other keyboards are not remapped.
- Optional login launch and an independent option to attempt remapping on app launch.

Requires an Apple Silicon Mac, macOS 13 or later, the Tartarus V2, and Xcode Command Line Tools to build. This project has been tested on one Apple Silicon Mac running macOS 27; older supported versions have not been tested on hardware. Other Razer models and Intel Macs are not validated.

## Build and open

This repository contains source code. No notarized installer is provided.

1. Install Apple's command line tools if they are not already installed:

   ```sh
   xcode-select --install
   ```

2. Clone and build:

   ```sh
   git clone https://github.com/harisucici/TartarusV2-For-Apple-chip.git
   cd TartarusV2-For-Apple-chip
   ./build.sh
   open "build/Tartarus Light.app"
   ```

The script builds an arm64 application, applies a local ad hoc signature, verifies it, and runs checks on Apple Silicon. Output is in `build/`; caches are in `.build/`. No third-party packages are required. Keep the app at a stable location; if you move it to Applications, grant permissions to that copy.

The local signature is not Apple notarization. Rebuilding or replacing the app can invalidate existing permission records, even if System Settings still shows their switches as enabled.

## Tutorial: lighting

1. Connect the Tartarus V2 and open **灯光效果** (Lighting).
2. Select the device. Use the refresh button if it is missing. The app binds to a USB location; reselect after changing USB ports.
3. Choose **固定颜色** (Solid), **光谱循环** (Spectrum cycling), or **关闭** (Off).
4. For a solid color, use **背光颜色** (Backlight color). Changes save and apply automatically; there is no Apply button.
5. In spectrum mode, choose **完整色谱** (Full spectrum) for the device's built-in effect, or **自定义颜色** (Custom colors).
6. For a custom cycle, edit each swatch, use **添加颜色** (Add color), the minus button to delete, and the up arrow to reorder. At least two colors remain; at most eight are allowed. **一轮时长** sets the duration of a complete cycle.

Custom cycling runs in software and requires the app to remain open. It sends at most ten volatile color updates per second; quitting or sleeping stops updates and leaves the last color. The built-in spectrum effect runs on the device. Lighting alone does not require Accessibility, Input Monitoring, or an administrator reader.

## Tutorial: permissions and remapping

Both permission categories use the same application name, **Tartarus Light**:

| System setting | Purpose |
| --- | --- |
| Privacy & Security → Accessibility | Sends remapped keystrokes from the ordinary user interface process. |
| Privacy & Security → Input Monitoring | Reads only the selected Tartarus keyboard interfaces in the input reader process. |
| Login Items, optional | Opens the app after login. |

On the tested Japanese macOS version, the Accessibility permission page is named **デバイスの制御とデータへのアクセス**; Input Monitoring is **入力監視**. macOS keeps the categories separate, so each must be enabled. The old `TartarusInput` and `Tartarus Control` entries are not used by this version. Permissions for unrelated software are independent.

1. Open **按键映射** (Key mapping) and select the target USB location.
2. Click **授予改键权限** (Grant remapping permissions), enable this app in both categories, then reopen it if needed.
3. Click **添加映射** (Add mapping). Select the source from its menu, or click **识别来源** (Identify source) and press the physical Tartarus key. Identification may request administrator approval, temporarily captures the selected device, and releases it after the source is learned. **识别按键** (Identify keys) continues until stopped.
4. Select the main target key. Enable any `⌘ Command`, `⇧ Shift`, `⌥ Option`, or `⌃ Control` buttons. Use **添加同时按下的键** to add additional simultaneous targets.
5. Examples: `1 → C` plus Command means Copy (`⌘C`); `1 → C` plus Command and Shift means `⌘⇧C`; `2 → C + V` holds both ordinary keys together. **快捷模板** provides Copy, Paste and Screenshot presets.
6. Click **保存映射** (Save mapping), then **授权启用改键** (Authorize and enable). Enter administrator credentials only in the macOS system dialog. Wait for **映射已启用** (Mapping enabled).
7. Focus the test field and check both the Tartarus and your ordinary keyboard. Shortcuts act on the focused application: for example, `⌘A` selects text rather than typing a letter.
8. Click **停止 / 恢复** (Stop / Restore), or press Escape while this app handles that shortcut, to release the device before editing. Exiting, disconnecting, sleeping, or switching sessions also stops remapping.

Holding a source holds its targets; releasing it releases them. Ordinary single keys repeat; shortcut and multi-key combinations do not auto-repeat. Unconfigured supported keys retain their original meanings. These combinations are simultaneous chords, not sequential macros.

The app uses a temporary administrator input process, not an installed background daemon. Starting mapping or identification may request administrator approval again. Enabling login launch does not bypass this approval.

## Tutorial: automatic startup

In Lighting, enable **登录后自动打开程序** (Open after login). macOS may require approval in Login Items. Lighting then restores automatically.

For mapping, separately enable **启动后自动尝试启用映射** (Attempt mapping on launch). The app attempts once per launch and may show administrator authorization. Cancellation or a missing device does not cause repeated prompts. Automatic mapping is disabled by default.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Device not found | Check the USB connection and refresh. This version matches only `1532:022B`. Reselect after changing ports. |
| `0xe00002c1` | Opening an exclusive keyboard interface needs administrator authorization. Use the app's authorized input mode. |
| `0xe00002e2` | Check Input Monitoring for the current **Tartarus Light** app. An old `TartarusInput` grant does not cover it. Also check for another application holding the device. |
| Permission is enabled, but the app says it is missing | After a rebuild or update, remove the stale entry, add the current app again, enable it, and restart the app. |
| Custom cycling stops | Keep the app running. It pauses on sleep/session changes. A failed USB response stops cycling and displays an error; change settings or reconnect to retry. |
| Deleting a color crashes an older build | Update to 0.5.1 or later. Stable color identities fix retained ColorPicker callbacks after deletion and reordering. |
| Shortcut behaves differently in an app/game | Check the focused app, input layout and that app's acceptance of synthetic keyboard events. Hardware compatibility is not guaranteed for every target app. |

Only the selected Tartarus keyboard interfaces are captured. Modifier state and application focus are shared by macOS, so holding a mapped modifier can affect concurrent typing normally; this does not remap another keyboard's source keys. Mouse buttons, wheel mapping, sequential macros, Fn/Caps Lock lock behavior, and some media/game inputs are unsupported or unvalidated.

## Configuration and source guide

Profiles stay on the local Mac and are not included in Git:

```text
~/Library/Application Support/TartarusLight/lights.json
~/Library/Application Support/TartarusControl/mapping.json
```

The source can migrate settings from the older `TartarusControl/profile.json` format. It does not alter another remapping application's configuration.

| Source | Role |
| --- | --- |
| `Sources/Main.swift`, `Theme.swift`, `LightView.swift` | App entry points, models and interface. |
| `Sources/LightController.swift`, `USBTransport.c/.h` | Automatic lighting, stable color identities and restricted USB transport. |
| `Sources/MappingEngine.swift`, `MappingController.swift`, `MappingView.swift` | Mapping transitions, profiles and UI. |
| `Sources/RootHelper.swift`, `PrivilegedInput.swift`, `IPC.swift`, `DeviceScope.swift` | Input-only administrator mode, local communication and exact device scope. |
| `Sources/StartupController.swift` | macOS login item registration. |
| `Sources/CoreChecks.swift`, `MappingChecks.swift` | Protocol, mapping, IPC, migration and deletion regression checks. |

To rerun checks without device commands or injected keystrokes:

```sh
"build/Tartarus Light.app/Contents/MacOS/TartarusLight" --self-test
```

Hardware checks on the development Mac covered simple Tartarus mappings with ordinary-keyboard isolation, unified permission naming, automatic lighting, and deleting/reordering colors during cycling. Logic checks cover modifier ordering, shared targets, releases, stale callbacks and 500 color edit cycles. This is not a compatibility certification for every shortcut, game, OS version or device.

Protocol reference: [OpenRazer](https://github.com/openrazer/openrazer). Acknowledgment of that reference does not imply an affiliation or endorsement.
