# Wine changes in the unofficial touchpad builds

The Wine patches behind the replaced DLLs of the `v0.4.0-touchpad.3` build. They go on top of the
Wine tree Playport 0.4.0 builds: its pin and `patches/wine-pe` series. The arm64ec ones also need
[#53](https://github.com/playportdev/playport/pull/53) (`wine-pe` 0045–0047), as in the earlier
touchpad builds.

The DLLs were built on macOS with llvm-mingw 20260922 and the configure flags of
`build/stages/wine-pe.sh`. Built unpatched from the same tree, the arm64ec DLLs listed below match
the 0.4.0 IPA byte for byte. The i386 ones differ only in winebuild's relay tables.

## arm64ec (64-bit games)

- `0001-ntdll-msvcrt-Stop-a-target-unwind-at-any-scope-recor.patch` builds `ntdll`, `ucrtbase`,
  `msvcrt`, `msvcr110` and `msvcr120`. clang splits one `__try` into several scope records.
  `__C_specific_handler` then ran a `__finally` early on a target unwind into an `__except`. A C++
  rethrow from a catch block unregistered its frame info twice and crashed in `_FindAndUnlinkFrame`:
  Baldur's Gate 3 did this when a level loaded. Reported in
  [#58](https://github.com/playportdev/playport/issues/58).
- `0002-user32-windows.gaming.input-Announce-host-pads-conne.patch` builds `user32` and
  `windows.gaming.input`. A pad connected while a game runs now gets `WM_DEVICECHANGE`, and a
  Windows.Gaming.Input provider. Disco Elysium needs this.
- `vcomp140.dll` is Wine's, unmodified. Baldur's Gate 3 imports it, and 0.4.0 has no arm64ec
  build of it; `main` already ships one.

## i386 (32-bit games)

All four came from Half-Life 2:

- `0001` (`kernelbase`): a new thread is returned only after it has started. Before, a thread
  suspended before its start never ran, and the game showed a black screen.
- `0002` (`kernelbase`): `MEM_DECOMMIT` takes only whole 16 KiB host pages. Before, it wiped
  live neighbours and the game crashed.
- `0003` (`kernelbase`): `SDL_JOYSTICK_RAWINPUT=0` by default. Before, the game saw no pad.
- `0004` (`dsound`): six periods are queued instead of three. Before, the sound crackled.

The touch pad library also sets `SDL_JOYSTICK_RAWINPUT=0` (`contrib/touchpad`), which covers
64-bit games.
