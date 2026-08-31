# BetterOSD

Bring back the classic volume and brightness feedback overlay to the center of your screen on macOS.

> [!IMPORTANT]
> **This fork** ([0x3654/better-osd](https://github.com/0x3654/better-osd)) extends the original [zmlabs/better-osd](https://github.com/zmlabs/better-osd) with:
>
> - 🖥 **External displays & clamshell mode** — F1/F2 brightness now controls external monitors and keeps working with the lid closed, via DDC/CI over `IOAVService` (the same channel macOS itself uses). The original app falls back to a broken, empty native OSD in this setup.
> - ⌨️ **Keyboard backlight OSD** — with configurable keys: **⌘F1/⌘F2** by default (zero changes to system key assignments) or **F5/F6** (auto-remap that preserves Dictation / Do Not Disturb).
> - 🔁 **No restart on lid open/close** — the app picks the right backend (built-in panel vs DDC) on every key press.
> - 🌍 **Русская локализация интерфейса**.
> - 📖 Detailed docs (features, settings, how-it-works) and demo GIFs below.

> Apple Silicon only (M-series Macs) · macOS 26 (Tahoe)+

| Classic | Modern |
|:---:|:---:|
| <picture><source media="(prefers-color-scheme: dark)" srcset="classic-dark.gif"><img src="classic-light.gif" alt="Classic HUD demo"></picture> | <picture><source media="(prefers-color-scheme: dark)" srcset="modern-dark.gif"><img src="modern-light.gif" alt="Modern HUD demo"></picture> |

---

## Features

- **Volume** — replaces the system HUD for volume up/down and mute
- **Display brightness** — replaces the system HUD for F1/F2 brightness keys, on the built-in display and external monitors (DDC/CI)
- **Keyboard backlight** — new OSD for ⌘F1/⌘F2 by default (F5/F6 also available)
- Two HUD styles: **Classic** (segmented bar) and **Modern** (pill with ticks)
- **Liquid Glass** effect with multiple variants
- Configurable position (bottom offset slider)
- Keyboard backlight key assignment — choose between F5/F6 or ⌘F1/⌘F2
- Launches at login, lives in the menu bar

---

## Download

| | Version | Signed |
|---|---|---|
| **This fork** (+ keyboard backlight, external-display brightness) | [v3.4.0](https://github.com/0x3654/better-osd/releases/latest/download/BetterOSD-arm64.dmg) | ✗ no certificate |
| **Official release** | [v3.2.0](https://github.com/zmlabs/better-osd/releases/latest/download/BetterOSD-arm64.dmg) | ✓ notarized |

1. Download the latest **BetterOSD-arm64.dmg**
2. Open the DMG and drag **BetterOSD.app** into **Applications**
3. Launch — grant **Accessibility** permission when prompted

> **Unsigned build note:** on first launch macOS will block the app.
> Right-click → **Open** → **Open**, or go to **System Settings → Privacy & Security → Open Anyway**.

---

## Settings

Open the menu bar icon → **Settings**.

| Section | What you can change |
|---|---|
| Appearance | HUD style, Liquid Glass on/off, glass variant, vertical position |
| Keyboard Backlight | Enable/disable OSD, choose key assignment (F5/F6 or ⌘F1/⌘F2) |
| General | Launch at login, show/hide menu bar icon |
| Updates | Auto-install updates |

### Keyboard backlight key assignment

Open **Settings → Keyboard Backlight**, enable the toggle, then pick your preferred key binding:

- **F5 / F6** — intercepts the standard illumination keys. BetterOSD also remaps F5/F6 to Dictation and Do Not Disturb at the system level so those functions are preserved alongside the OSD.
- **⌘F1 / ⌘F2** — intercepts Command + display-brightness keys. No system remapping applied; bare F1/F2 continue to control display brightness normally.

---

## How it works

BetterOSD installs a CGEvent tap (requires Accessibility permission) and intercepts media key events before they reach the system. For each key it handles, BetterOSD suppresses the native system HUD, applies the change itself, and shows its own overlay. Events it doesn't handle are passed through unchanged.

Keyboard backlight brightness is read and written via `CoreBrightness.framework` (`KeyboardBrightnessClient`). Display brightness uses `DisplayServices.framework` for the built-in panel; external monitors are driven over DDC/CI (VCP `0x10`) through `IOAVService`, the same channel macOS itself uses. All private frameworks are loaded at runtime.

> **Note (external displays):** DDC/CI reads are unreliable on some setups — e.g. Dell monitors while Dell Display Manager is running answer with garbage. There BetterOSD caches the last written brightness per display (persisted across launches), so the very first key press after a fresh install steps from an assumed 75% level. DDC writes themselves work fine.

> **Lid closed (clamshell):** with the lid closed `DisplayServices.framework` reports no controllable display (`CanChangeBrightness = false`, `SetBrightness` is a silent no-op on externals), which is why the app falls back to DDC automatically — no restart needed when you open/close the lid.

---

## App Store

**App Store link:** https://apps.apple.com/us/app/volume-hud/id6752903119

Due to the use of private APIs and Accessibility permissions, we can no longer ship updates via the App Store. The App Store version will not be updated.

---

## Notes

- You'll be prompted for **Accessibility** permission so BetterOSD can listen for media keys.
- Supports volume, brightness (built-in and external) and keyboard backlight HUD feedback.
- Keyboard backlight OSD is opt-in — enable it and pick the keys in **Settings → Keyboard Backlight**.
- Only supports Apple Silicon (M-series Macs).

---

## Building from source

```bash
git clone https://github.com/0x3654/better-osd
cd better-osd
open BetterOSD.xcodeproj
```

Requires Xcode 26+ and the macOS 26 SDK. No external dependencies beyond Swift Package Manager (Sparkle, LaunchAtLogin — resolved automatically).
