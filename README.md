# spotify-qt on Windows, with local playback

Setup script and field notes for running [spotify-qt](https://github.com/kraxarn/spotify-qt)
on Windows x64 with **local speaker playback**, without installing Qt, Visual Studio,
or the official Spotify client.

```powershell
.\setup.ps1
```

Re-runnable. It skips what is already done and backs up the spotify-qt config before
touching it.

## What it sets up

1. **spotify-qt** from the upstream prebuilt `win64` release, unpacked to
   `%LOCALAPPDATA%\Programs\spotify-qt`. Self-contained, Qt DLLs bundled by
   `windeployqt`, so no Qt install and no compiler.
2. **librespot**, built from crates.io, which is what actually decodes audio and
   registers as a Spotify Connect device on your speakers.
3. **The wiring**, so librespot starts and stops together with spotify-qt and you
   never launch it by hand.

Uninstall is deleting `%LOCALAPPDATA%\Programs\spotify-qt`, `~\.cargo\bin\librespot.exe`,
and the Start Menu shortcut. Nothing goes into Program Files or the registry.

## The thing that confuses everyone first

**spotify-qt never plays audio.** It is a Spotify Connect remote. On a fresh machine
its device list is empty and nothing you click produces sound, which reads like a bug
and is not one.

For your local speakers to appear, some process on the machine has to register *itself*
as a Connect device. That is librespot's job. spotify-qt is built to launch and manage
it (`src/spotifyclient/runner.cpp`), it just does not ship it.

## Gotchas, in the order you hit them

**1. librespot ships no Windows binaries.**
Release v0.8.0 has zero assets and there is no winget package. It has to be compiled.
Requires [rustup](https://rustup.rs).

**2. The MSVC toolchain needs Visual Studio, which you probably do not want.**
Rust's default `x86_64-pc-windows-msvc` cannot link without the MSVC linker and Windows
SDK libs, roughly 3 to 7 GB. The GNU toolchain avoids that:

```powershell
rustup toolchain install stable-x86_64-pc-windows-gnu
```

This works here because librespot's Windows defaults are `native-tls` (SChannel),
`rodio` (WASAPI) and `libmdns`, all pure Rust. No OpenSSL, no `ring`, so no C compiler
is required.

**3. `rustup`'s GNU toolchain still is not enough.** This is the wall:

```
error: error calling dlltool 'dlltool.exe': program not found
error: could not compile `windows-sys` (lib) due to 1 previous error
```

The `rust-mingw` component provides a linker but **not** `dlltool.exe`. The
`windows-sys` crates use `raw-dylib` on the GNU target and need `dlltool` to generate
import libraries. Fix by installing MinGW-w64 binutils:

```powershell
winget install --id BrechtSanders.WinLibs.POSIX.MSVCRT
```

Then put its `mingw64\bin` on `PATH` for the build.

**4. Pick the MSVCRT variant, not UCRT.** Rust's `x86_64-pc-windows-gnu` target links
against msvcrt, so the MSVCRT WinLibs build stays consistent with the `rust-mingw` libs
rustup already installed. The UCRT variants mismatch.

**5. Do not edit the config while spotify-qt is running.** It rewrites
`%LOCALAPPDATA%\kraxarn\spotify-qt.json` on exit, so a live process silently discards
your changes. That file also holds your access and refresh tokens, which is why the
script backs it up and verifies the token survived the write.

**6. The taskbar pin cannot be scripted.** Windows 11 exposes no pin-to-taskbar shell
verb, and pin-to-Start returns `E_ACCESSDENIED` for non-interactive callers. The only
programmatic route left is hand-writing the `Taskband` registry blob, which wipes your
existing pins when it goes wrong. Right-click the running icon instead. The script does
create a Start Menu shortcut, so it is at least searchable.

## After the script

1. **Bring your own Spotify app credentials.** spotify-qt bundles none. Create an app at
   [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and set the
   redirect URI to exactly `http://127.0.0.1:8888`. The setup dialog is strict about it.
2. **Authorize librespot once.** On first start spotify-qt passes `--enable-oauth`,
   watches librespot's stdout for the authorize URL and opens your browser
   (`src/spotifyclient/runner.cpp:158`). Approve there. Credentials are then cached under
   `%LOCALAPPDATA%\kraxarn\spotify-qt\cache\librespot`.
3. **Select the device:** hamburger menu → **Device** → `spotify-qt@<hostname>`.

## Other things worth knowing

**Playback requires Spotify Premium.** Everything above can be wired perfectly and
librespot will still refuse to stream on a free account. The Connect control API is
Premium-only too.

**The window seems unresizable.** By default spotify-qt draws a borderless window with a
custom title bar, and resizing falls back to invisible corner grips. Settings →
Interface → untick **"Application title bar"**, then restart. You get the native Windows
frame and normal edge-drag resizing, at the cost of the integrated title bar buttons.

**Updating spotify-qt** means re-running the script with `-Force`. There is no
auto-update on the portable build.

**Updating librespot** means `cargo install librespot --locked` again, with the MinGW
`bin` on `PATH`, or you get the `dlltool` error from gotcha 3.

## Verified on

Windows 11 Enterprise 26100, x64, spotify-qt v4.0.4, librespot 0.8.0,
Rust 1.97.1 (`stable-x86_64-pc-windows-gnu`), WinLibs binutils 2.47.
Build took about 5m30s on 14 cores.

## Credit

[spotify-qt](https://github.com/kraxarn/spotify-qt) is by
[kraxarn](https://github.com/kraxarn), [librespot](https://github.com/librespot-org/librespot)
by the librespot-org project. This repo is only the Windows setup recipe and contains no
code from either.
