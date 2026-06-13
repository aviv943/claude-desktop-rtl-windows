# Claude Desktop RTL — Windows

Patches [Claude Desktop](https://claude.ai/download) on Windows to add full **right-to-left (RTL) text support** for Hebrew and Arabic — in the chat input, in Claude's responses, and in mixed-direction text.

Out of the box, Claude Desktop renders Hebrew and Arabic left-to-right, making text appear backwards and misaligned. This patch fixes that by injecting a smart RTL-detection script directly into the app's renderer.

> Ported from the Mac version by [@soguy](https://github.com/soguy/claude-desktop-rtl-mac), using the RTL payload originally authored by [@shraga100](https://github.com/shraga100/claude-desktop-rtl-patch).

---

## Features

- **Chat input** — direction switches automatically as you type: Hebrew/Arabic → right-to-left, Latin → left-to-right
- **Claude's responses** — each paragraph is independently detected and aligned
- **Mixed content** — lines of different scripts in the same message each get their own direction
- **Code blocks** — always stay left-to-right regardless of surrounding language
- **Auto-update** — a scheduled task re-applies the patch at every logon after Claude auto-updates, silently and transparently

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (x64) |
| Claude Desktop | MSIX version from [claude.ai/download](https://claude.ai/download) |
| Node.js | v18 or later — [nodejs.org](https://nodejs.org) |
| Permissions | Administrator (UAC prompt, one time per patch) |

## Installation

### Option A — Double-click (recommended)

1. Download or clone this repository
2. Double-click **`install.bat`**
3. Approve the UAC prompt
4. Claude restarts automatically with RTL support active

### Option B — PowerShell

```powershell
.\patch.ps1 -Install
```

No separate shortcut is needed — the normal Claude Desktop shortcut opens the patched version.

## Usage

```powershell
# Install or re-install the patch
.\patch.ps1 -Install

# Re-patch even if the version hasn't changed (e.g. after editing rtl-payload.js)
.\patch.ps1 -Install -Force

# Show current patch state
.\patch.ps1 -Status

# Generate a diagnostic report (attach to GitHub issues)
.\patch.ps1 -Diagnose

# Remove the patch and restore Claude to its original state
.\patch.ps1 -Uninstall
```

## How it works

Claude Desktop is distributed as an MSIX package under `C:\Program Files\WindowsApps\`. Its UI is an Electron renderer that loads JavaScript from `app.asar` inside the package.

**The patcher (`patch.ps1`):**

1. Backs up the original `app.asar` once per Claude version
2. Extracts the archive, prepends `rtl-payload.js` to every `.vite/build/*.js` renderer file, and repacks
3. Disables the Electron `EnableEmbeddedAsarIntegrityValidation` fuse on `claude.exe` so the modified archive loads without integrity errors
4. Registers a Windows scheduled task (at logon, elevated, 30 s delay) that automatically re-patches after Claude auto-updates

**The payload (`rtl-payload.js`):**

- **First-strong algorithm** — the first Hebrew/Arabic or Latin character in each element determines its direction
- **LTR-prefix stripping** — file paths, URLs, and inline code at the start of a paragraph are stripped before direction is decided, preventing false RTL detection
- **Mixed-line splitting** — elements whose lines (separated by `<br>` or newlines) contain different scripts are split into per-line `<span dir="...">` blocks at runtime
- **Computed-style inheritance guard** — English elements that inherit RTL from a parent are explicitly forced to `dir="ltr"` using `getComputedStyle`, catching direction applied via CSS classes rather than HTML attributes
- **Code block protection** — `<pre>`, `<code>`, and `.code-block__code` elements are always forced LTR
- **MutationObserver** — processes Claude's streaming responses in real time as new DOM nodes are added, with a 50 ms debounce

## Auto-update behavior

Claude auto-updates silently. After an update the patch is no longer active until re-applied.

- **At logon**: the registered scheduled task fires 30 seconds after login and re-patches automatically — no action needed
- **Manually**: run `.\patch.ps1 -Install` at any time to re-patch immediately
- **Status check**: `.\patch.ps1 -Status` shows whether the installed Claude version matches the patched version

## Uninstall

```powershell
.\patch.ps1 -Uninstall
```

Restores the original `app.asar` from backup, re-enables the Electron fuse, removes the scheduled task, and restarts Claude. Claude is left in its factory state.

## Troubleshooting

**Claude won't open after patching**

```powershell
.\patch.ps1 -Uninstall
```

This always works because the original `app.asar` is backed up before any changes are made.

**"Node.js not found"**  
Install Node.js from [nodejs.org](https://nodejs.org) and rerun the patcher.

**"Claude Desktop (MSIX) not found"**  
Make sure Claude Desktop was installed from [claude.ai/download](https://claude.ai/download). Portable or manually extracted builds are not supported.

**After a Claude update the patch disappeared**  
This is expected. Either wait for the next logon (the scheduled task re-patches automatically) or run `.\patch.ps1 -Install` immediately.

**Global hotkeys (AutoHotkey, dictation tools, etc.) stop working while Claude is focused**  
The patcher launches Claude at *normal* integrity precisely to avoid this. If Claude was patched by an older version it may still be running **elevated**, and Windows UIPI prevents a non-elevated global keyboard hook (`WH_KEYBOARD_LL`) from seeing keys sent to an elevated window — so those hotkeys silently do nothing in the Claude window only. Fix: fully quit Claude (system tray → Quit, or Task Manager → end all `Claude` processes) and reopen it normally from the Start menu. It will run at normal integrity and your global hotkeys will work over Claude again.

**Generate a diagnostic report**

```powershell
.\patch.ps1 -Diagnose
```

This creates `claude-rtl-diagnose.txt` on your Desktop with OS info, Claude version, fuse state, payload presence check, scheduled task state, and recent logs. Attach it to any GitHub issue.

## Project structure

```
claude-desktop-rtl-windows/
├── patch.ps1          # Installer, uninstaller, and status checker
├── rtl-payload.js     # RTL detection script injected into Claude's renderer
├── install.bat        # Double-click shortcut to run the installer
└── README.md
```

## Credits

- RTL payload — [@shraga100](https://github.com/shraga100/claude-desktop-rtl-patch)
- Mac version — [@soguy](https://github.com/soguy/claude-desktop-rtl-mac)
- Windows port — [@Aviv943](https://github.com/Aviv943)

## License

[MIT](LICENSE)
