# 2026-10-23: Baldur's Gate 3 on DXMT

Material for the Baldur's Gate 3 report in playportdev/playport (Steam 1086940, build 25605617,
iPhone 17 Pro Max, iOS 27.0.1, a re-signed 0.4.0 with replaced DLLs). The issue lists the changes the
game needed.

- `wine-pe-ntdll-msvcrt-target-unwind.patch`: Wine's `__C_specific_handler` (`ntdll/unwind.c` and
  `msvcrt/except.c`) stops a target unwind at a scope record of the same `__try`, as Windows does.
  Without it, a C++ rethrow from a catch block unregisters its frame info twice in
  `call_catch_block4` and crashes in `_FindAndUnlinkFrame`. It applies to `main`'s Wine tree.
- `bg3-lower-city-1.jpg`, `bg3-lower-city-2.jpg`: Act 3, the Lower City, 7.7 and 9.9 FPS, DXMT, Metal HUD on.
- `bg3-nautiloid.jpg`: the Nautiloid, 14 FPS.
