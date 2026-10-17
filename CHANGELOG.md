# Changelog

## 2026-10-17-v9 (Latest)

- Convert to menu bar app (hidden from Dock, `LSUIElement=YES`)
- Add in-app language switching: English, 简体中文, 繁體中文, 日本語
- Add `LocaleManager` with `Bundle` swizzling for runtime localization
- Add Tartarus key mapping support
- Simplify mapping UI: remove identify buttons, auto-enable after save
- Fix menu bar activation, localized sidebar and quit confirmation
- Change default light cycle duration to 10 seconds
- Add author info (Harisucici) to about dialog

## 0.5.1

- Fix crash when deleting or reordering colors during custom cycling (stable color identities for retained `ColorPicker` callbacks)
- Initial public release with lighting controls and device-specific key remapping for Razer Tartarus V2 (`1532:022B`) on Apple Silicon
