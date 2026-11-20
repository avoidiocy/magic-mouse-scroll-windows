# How it works

## Why the Magic Mouse does not scroll on Windows

The Magic Mouse is a Bluetooth HID device. Its report descriptor (dumped in
[magic_mouse_2024_bt_report_descriptor.txt](magic_mouse_2024_bt_report_descriptor.txt))
declares a single mouse input report, ID `0x12`: two buttons, 16-bit relative
X/Y, two padding bytes - eight bytes, **no wheel**. The touch surface is not
declared at all.

A host that wants touch data has to send the vendor feature report
`F1 02 01` ("enable multitouch"). The mouse then keeps sending report `0x12`,
but longer: `14 + 8*N` bytes, with up to N finger contacts appended. The
Linux kernel driver (`hid-magicmouse`) and macOS do exactly this.

On Windows this cannot be done from user space, and not even from a regular
HID filter driver: `hidclass.sys` trusts the descriptor and truncates every
`0x12` report to the declared eight bytes before any HID-level consumer sees
it. The only place to intercept the full frames is *below* `hidclass`, between
`hidbth.sys` (Bluetooth HID transport) and `bthport.sys`.

## Apple's Boot Camp driver

Apple's `applewirelessmouse.sys` (6.0.6200.0, 2015, WHQL-signed by Microsoft)
is such a lower filter. Apple's own `AppleWirelessMouse.inf` installs it with

```
[AppleWirelessMouse.NT.HW.AddReg]
HKR,,"LowerFilters",0x00010000,"applewirelessmouse"
```

under `Include=hidbth.inf`. The driver enables multitouch on the mouse,
replaces the HID descriptor seen by Windows with a mouse that has a vertical
wheel and horizontal pan, and translates finger movement into wheel reports.
Because the result is an ordinary HID mouse, Windows' own `mouhid.sys` handles
it and scrolling works everywhere.

Apple's INF only lists three hardware IDs (`VID&000205ac_PID&030d`,
`VID&000205ac_PID&0310`, `VID&0001004c_PID&0269`). Newer models such as the
Magic Mouse 2024 (`VID&0001004c_PID&0323`) are never matched, so Windows never
installs the filter - even though the driver itself handles them fine.

## What the installer does

1. Downloads Apple's software-update catalog, picks the smallest
   `BootCampESD.pkg`, downloads it from Apple's CDN and unpacks the chain
   `pkg -> Payload -> WindowsSupport.dmg -> BootCamp\Drivers\Apple\AppleWirelessMouse64.exe -> AppleWirelessMouse.sys`
   with 7-Zip.
2. Verifies the `.sys`: SHA-256
   `EEA7CEE897A04FE4617E93BE2E420EB7F40E89D6A1686101E1E060DDAD2BD564`, version
   6.0.6200.0, and a valid Authenticode signature by *Microsoft Windows
   Hardware Compatibility Publisher*. The unmodified file also passes
   `signtool verify /kp` (kernel-mode policy), which is why it loads with
   Secure Boot enabled.
3. Copies it to `System32\drivers`, creates the kernel service
   `applewirelessmouse` (demand start, as in Apple's INF) and prepends
   `applewirelessmouse` to `LowerFilters` on the registry key of the mouse's
   `BTHENUM\{00001124-...}_VID&0001004C_PID&xxxx\...` device instance - the
   same registry value Apple's INF writes, just for a device Apple's INF does
   not list.
4. Restarts that device (`pnputil /restart-device`). The stack is rebuilt as
   `bthport -> applewirelessmouse -> hidbth -> hidclass -> mouhid`.

Uninstall removes the `LowerFilters` entry, restarts the device, deletes the
service and the driver file.

## Known limitations

- Scrolling is reported in whole wheel detents (+/-120), not high-resolution,
  and without inertia - that is how Apple's 2015 driver behaves.
- No gestures. Apple's driver consumes the touch data in the kernel and
  exposes only a settings IOCTL on its control device
  (`\\.\AppleBluetoothMultitouch`, used by the Boot Camp control panel), so a
  user-mode gesture layer cannot be built on top of it.
- The battery collection of the mouse is hidden by Apple's descriptor rewrite.
