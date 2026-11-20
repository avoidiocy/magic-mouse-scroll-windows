<p align="center">
  <img src="assets/logo.png" alt="F²" width="160">
</p>

# Magic Mouse Scroll for Windows

Makes the touch surface of an **Apple Magic Mouse** scroll on **Windows 10 / 11** –
vertically and horizontally, system-wide, with **Secure Boot left on** and no
test-signing mode.

Made by **F²**. Free, open source (MIT).

## What it does

Out of the box, Windows only sees the Magic Mouse as a plain two-button mouse:
the Bluetooth HID descriptor it reports contains no scroll wheel, and the touch
data never reaches Windows.

Apple ships a Windows driver for the Magic Mouse with Boot Camp
(`applewirelessmouse.sys`). It is signed by Microsoft (WHQL), so Windows loads it
on any PC – but Apple's installer only knows the Magic Mouse models that existed
in 2015, so on a Magic Mouse 2 / Magic Mouse (2024, USB-C) it simply never gets
installed.

This installer:

1. downloads Apple's Boot Camp support package **directly from Apple's servers**
   (`swcdn.apple.com`, about 330 MB) and extracts the mouse driver from it,
2. verifies the driver file (SHA-256 and the Microsoft Authenticode signature),
3. registers it exactly the way Apple's own `AppleWirelessMouse.inf` does – as a
   kernel *lower filter* on the Magic Mouse's Bluetooth HID device, and
4. restarts that one device. The mouse starts scrolling immediately; no reboot.

Nothing else on the system is touched. `Uninstall.cmd` reverts every change.

> Apple's driver is **not** included in this repository or its releases. Your
> computer downloads it from Apple; Apple's software license applies to it.

## What you get – and what you don't

| | |
|---|---|
| Vertical scrolling | yes |
| Horizontal scrolling | yes |
| Works in elevated apps / UAC prompts / login screen | yes (it is a real HID wheel, not an injected event) |
| Secure Boot, no test mode | yes |
| Smooth / high-resolution scrolling, momentum | no – scrolling is in whole wheel "notches" |
| Gestures (swipe, Mission-Control-style) | no |
| Battery level in Windows | no (Apple's driver hides the battery collection) |

If you need gestures or smooth scrolling, a commercial driver such as Magic
Utilities is currently the only option on Windows.

## Supported hardware

Bluetooth Apple mice: Magic Mouse (2009, PID `030D`), Magic Mouse 2 (PID `0269`)
and Magic Mouse 2024 / USB-C (PID `0323`). Tested on Windows 11 24H2 x64 with
a Magic Mouse (2024).

## Install

1. Pair the Magic Mouse in *Settings > Bluetooth & devices* and make sure the
   pointer moves.
2. Download the latest release ZIP from
   <https://github.com/avoidiocy/magic-mouse-scroll-windows/releases> and extract it.
3. Double-click **`Install.cmd`**. Accept the UAC prompt, read the summary and
   confirm. The ~330 MB download from Apple takes a minute or two.
4. Scroll.

Keep a keyboard or a second mouse within reach for the few seconds the device
is restarted – if anything goes wrong the pointer may stop until you run
`Uninstall.cmd`.

### Uninstall

Double-click **`Uninstall.cmd`**. The device is restored to the stock Windows
driver stack and Apple's driver file is removed.

### Command line

```
MagicMouseScroll.ps1 -Install       [-Yes] [-DriverPath <AppleWirelessMouse.sys>] [-InstanceId <id>]
MagicMouseScroll.ps1 -Uninstall
MagicMouseScroll.ps1 -Status
MagicMouseScroll.ps1 -DownloadOnly  [-WorkDir <dir>]   # fetch + verify the driver, change nothing
```

`-DriverPath` lets you reuse an already extracted `AppleWirelessMouse.sys`
(6.0.6200.0) for offline installs; it is still hash- and signature-checked.

## Requirements

- Windows 10 (1809 or later) or Windows 11, 64-bit, Bluetooth.
- Internet access to `swscan.apple.com` / `swcdn.apple.com` (and `7-zip.org`
  if 7-Zip is not installed – a portable copy is downloaded to the work folder
  and used only for extraction).
- Administrator rights (the installer elevates itself).

## How it works, in more detail

See [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). The stock Bluetooth HID
report descriptor of the Magic Mouse 2024 is in
[docs/magic_mouse_2024_bt_report_descriptor.txt](docs/magic_mouse_2024_bt_report_descriptor.txt).

## Troubleshooting

- **"No Magic Mouse found"** – pair the mouse first; make sure it shows up
  under *Bluetooth & devices* and the pointer moves.
- **Device shows an error / pointer dead after install** – run
  `Uninstall.cmd` (keyboard: `Win+R`, type the path, Enter). Then open an
  [issue](https://github.com/avoidiocy/magic-mouse-scroll-windows/issues) with
  the output of `MagicMouseScroll.ps1 -Status`.
- **Download fails** – Apple occasionally re-publishes the catalog. Run
  `MagicMouseScroll.ps1 -DownloadOnly` to see the exact error, or extract
  `AppleWirelessMouse.sys` yourself from a Boot Camp package and use
  `-DriverPath`.
- **The mouse was re-paired / a new Magic Mouse** – just run `Install.cmd`
  again; it is idempotent.

## Legal

- The scripts and documentation in this repository are © F² and released
  under the [MIT License](LICENSE). That license covers **only** our own
  work; it grants no rights of any kind to Apple's driver, 7-Zip or any
  other third-party component the installer downloads (see the scope
  section in [LICENSE](LICENSE)).
- Apple, Magic Mouse and Boot Camp are trademarks of Apple Inc. This project is
  not affiliated with or endorsed by Apple. Apple's driver is downloaded by you
  from Apple and is governed by Apple's Boot Camp software license, which is
  shown to you during installation (`EnglishLicense.txt` in the work folder).
  Apple's license is written for Apple-branded computers; whether using it on
  a PC is permitted is between you and Apple – this project makes no
  representation about that.
- 7-Zip is © Igor Pavlov, LGPL; it is downloaded from 7-zip.org when needed
  and not bundled.

## Credits

The approach – reusing Apple's signed Boot Camp filter driver for newer Magic
Mouse models – was first described by community projects such as
[sbagirici/apple-magic-mouse-scroll-fix-windows](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) and
[LesleyMurfin/magic-mouse-v3-windows-fix](https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix).
This project re-implements it without redistributing or modifying Apple's
binary.
