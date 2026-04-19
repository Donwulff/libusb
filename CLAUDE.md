# Libusb Fork — Windows RDS USB Enumeration Fix

Fork of libusb carrying fixes to make USB devices redirected through Windows RDS/Terminal Services work correctly. Not intended for upstream submission (yet) — see "Decisions made" below.

## The problem

USB devices redirected through Windows Terminal Services appear under a non-standard enumerator (`TS_USB_HUB_Enumerator`) that does not look like a real USB hub. Stock libusb walks the hub topology during enumeration and misses these devices entirely. Symptoms:

- `listdevs.exe` doesn't show RDS-redirected devices.
- Applications (including pyusb-based tools like TI's simplelink-wifi-toolbox) return empty device lists.
- The Citrix "custom bulk endpoints don't work" advisory from TI is a **different** issue — Citrix does class-level redirection, RDS does raw USB passthrough. Our problem is purely enumeration.

Primary test device: TI XDS110 debug probe (VID_0451 / PID_BEF3), used by TI CCS/DSLite, simplelink-wifi-toolbox, and other chip-bringup tools. Validated on CC1354P10; target is CC3551e (hardware not yet available at the time of writing).

## Repository layout

- `origin` = this fork (donwulff/libusb on GitHub). Push target.
- `upstream` = libusb/libusb (mainline). Configured as a remote; fetch directly with `git fetch upstream`.
- Working branch: `fix/rds-usb-enumeration`.

## Upstream sync workflow

To bring upstream changes into the feature branch:

```bash
git fetch upstream
git checkout fix/rds-usb-enumeration
git merge upstream/master
# Resolve any conflicts (libusb/os/windows_winusb.c is the hotspot — our
# changes overlap with upstream's ongoing work there).
git push origin fix/rds-usb-enumeration
```

Keep the fork's `master` in sync via GitHub's "Sync fork" button, or locally:

```bash
git fetch upstream
git checkout master
git merge --ff-only upstream/master
git push origin master
```

Use merge, not rebase — branch history already uses merge commits (see `ffd88ec`, `f2946b5`), and the branch has been pushed, so rebasing would rewrite published history.

## Branch commits (fix/rds-usb-enumeration)

| Commit | Summary |
|--------|---------|
| `08934f4` | Diagnostic logging for USB device enumeration ancestry |
| `2e46394` | Handle USB devices under non-standard bus enumerators (RDS fix, `init_device_from_devid`) |
| `42a94dd` | Fetch config descriptors via WinUSB for hubless devices |
| `dcf1afd` | Add timeout to synchronous `DeviceIoControl` calls (`sync_ioctl` wrapper) |
| `fb0673f` | Set 5-second default `PIPE_TRANSFER_TIMEOUT` for WinUSB pipes |
| `c3b61e6` | Use finite timeout when waiting for IOCP thread on exit |
| `835bf0f` | Fix handle leak in `winusbx_open()` on partial failure |
| `df62d37` | Fetch **real** device/config descriptors during enumeration (fixes pyusb) |
| `43902a8` | Add Windows libusb deployment tool (`deploy_libusb.ps1`) |

## Technical notes worth remembering

### Enumeration

- libusb enumeration runs multiple passes: `HUB_PASS → DEV_PASS → HCD_PASS → GEN_PASS → HID_PASS → EXT_PASS`. RDS devices slip through because there's no real hub above them.
- `init_device_from_devid()` parses the PnP device instance ID (`VID_xxxx&PID_xxxx&REV_xxxx`) and builds a synthetic `libusb_device_descriptor`. `bcdUSB=0x0200`, `bMaxPacketSize0=64`, `bcdDevice` from `REV_`.
- The synthetic descriptor is **not enough** on its own. pyusb's `find()` calls `libusb_get_config_descriptor()` during enumeration and silently skips devices where it fails. Real device descriptor and at least one config descriptor **must** be cached at enumeration time, not lazily at `claim_interface()`.
- Post-enumeration in `winusb_get_device_list()`: for each device without cached config descriptors that has a WinUSB-capable interface, open a temporary WinUSB handle and use `ControlTransfer` to fetch the real device descriptor and each config descriptor. Close the temporary handle when done.

### WinUSB quirks

- Availability check: `WinUSBX[sub_api].hDll == NULL`. There is no `initialized` field — don't reach for one that looks obvious (this bit me).
- The `Initialize`/`Free` API-table calls are what manage the WinUSB interface handle; `CreateFile`/`CloseHandle` manage the underlying device handle. Both pairs must match.
- `PIPE_TRANSFER_TIMEOUT` defaults to infinite. Setting it to 5000 ms via `SetPipePolicy` prevents permanent lockups when a device stops responding.

### Memory contract

`winusb_device_priv_release()` frees config descriptors at `ptr - USB_DESCRIPTOR_REQUEST_SIZE`. When caching config descriptors manually, allocate with that header offset and store the data pointer at `+USB_DESCRIPTOR_REQUEST_SIZE`. Breaking this layout is a silent heap corruption waiting to happen.

### Build-environment gotchas

- **C89 compatibility is required.** MSVC C89 mode (what the Windows build uses) disallows `for (int i = ...)` and most mid-block declarations. Wrap loop-local variables in block scope: `{ int j; for (j = ...) { ... } }`.
- Variable shadowing within nested scopes will warn on MSVC. Rename aggressively.
- `version.h` may be updated externally during the release process (e.g., `1.0.29` → `1.0.30-rc1`); don't edit it by hand unless bumping the fork's own version.

## Debugging & testing

- `LIBUSB_DEBUG=4` on the Windows target gives full enumeration trace. Combine with application-level logs to see where a device gets lost (libusb often finds it; the app may skip it).
- Local test binaries from MSBuild output: `listdevs.exe`, `xdsdfu-e.exe`.
- When pyusb returns `Founded devices : []` but libusb logs show the device: the issue is descriptor caching, not enumeration.

## Deployment: `scripts/windows/deploy_libusb.ps1`

Four modes to manage the fixed `libusb-1.0.dll` across TI/vendor tool installations (TI bundles libusb per-product, 20+ copies on a typical install):

- `-List` — show every `libusb-1.0.dll` on the system with architecture (x86/x64), version, and whether a `.bak` exists.
- `-Replace -SourceDll <path>` — for each copy whose architecture matches `-SourceDll`, back up to `.bak` and replace. Skips arch-mismatched copies automatically (don't put x64 DLLs into 32-bit tools).
- `-Watch -SourceDll <path> [-App <exe>]` — starts a `FileSystemWatcher` on `%TEMP%` to catch PyInstaller-style self-extracting apps that drop a bundled libusb into a `_MEI*` directory at runtime. With `-App`: launches the app, patches the extracted DLL, waits for app exit. Without `-App`: runs as a daemon until Ctrl+C.
- `-Restore` — restore every `.bak` found.

The Watch mode is deliberately generic (not PyInstaller-specific). Any runtime DLL extraction under `%TEMP%` gets patched.

## Related issues that look similar but aren't

- **Citrix "custom bulk endpoints"** — different passthrough model. Not our problem; RDS uses raw USB passthrough.
- **J-Link firmware updates over RDS** — device re-enumerates mid-update; the virtual hub doesn't reattach cleanly. Use a local session for firmware updates. Not fixable from libusb.
- **jlinkx64.sys BSOD** — SEGGER kernel driver bug, probably triggered by corrupted adapter state. Separate from libusb issues.

## Decisions made

- **Not upstreaming right now.** TI bundles a specific libusb version and doesn't update it; an upstream merge wouldn't propagate to their tools. If a PR is made in the future, avoid company attribution — "we develop on RDS" is marginally useful info to hackers and isn't a competitive advantage worth advertising.
- **Fork stays public** on GitHub — most convenient path and no competitive sensitivity.
- **Production stability** is the dominant constraint: version bumps, DLL swaps, etc. are minimized and coordinated with whoever is actively using the tools.
