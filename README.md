# MemorySpy

An ultra-lightweight native macOS menu bar memory monitor (~149 KB binary) built with pure Swift, AppKit, and Darwin Mach/libproc APIs.

轻量级 macOS 原生菜单栏内存监控小工具，告别笨重卡顿的活动监视器。

## Highlights
- **Segmented Menu Bar Ring**: Bold 10-segment circular gauge (`18×18 pt`) that adapts automatically to light/dark menu bars (`isTemplate`), highlighting warning/critical memory pressure in amber/red.
- **On-Demand Process Inspector**: Click the menu bar ring to view real-time memory usage (`App + Wired + Compressed + Swap`), kernel memory pressure, and top 50 processes by actual `phys_footprint`.
- **All / Grouped Modes & Quick Actions**: Switch between individual PIDs and app-grouped totals, filter by name/PID, hover `✕` to quit (hold `Option` to Force Quit), or right-click for `Copy PID` / `Reveal in Finder`.
- **Extreme Lightweight Design**:
  - Zero SwiftUI, zero Electron, zero third-party dependencies, no Dock icon (`LSUIElement`).
  - While closed, only samples lightweight kernel VM stats (`host_statistics64` + `sysctlbyname`) every 3s and skips icon redraws unless percentage or pressure changes.
  - Process scanning (`proc_listallpids` + `proc_pid_rusage`) runs **only while the popover is open**.
- **Generated App Icon**: `build.sh` procedurally generates `AppIcon.icns` across all standard macOS resolutions (`16×16` to `512×512@2x`).

## Build & Run
```zsh
./build.sh
open MemorySpy.app
```

To install into `/Applications`:
```zsh
cp -R MemorySpy.app /Applications/
open /Applications/MemorySpy.app
```
