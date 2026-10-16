# Emberlight Companion on a Mac (preview)

The Mac version is a **preview**: it's built from the same code as the Windows one, but it hasn't
been tested with WoW: Forever on a Mac yet. If you try it, tell us on Discord how it went.

The addon works on a Mac exactly as on Windows. If you only want the addon, see
[Just the addon](INSTALL-WINDOWS.md#just-the-addon); on a Mac the game folder is
`/Applications/World of Warcraft`.

## Why the Mac warns you

Apple only lets an app open without a warning if its maker pays for an Apple developer account.
Emberlight is a volunteer project and doesn't, so the first time you open it the Mac says it
**can't check the app for malicious software**. The code is all here for anyone to read, and the
download is built from it by GitHub (see the README).

## Install

1. Download **[Emberlight-Companion-Mac.dmg](https://github.com/rsamuelsen/emberlight-app/releases/latest/download/Emberlight-Companion-Mac.dmg)**.
2. Open the downloaded file and drag **Emberlight Companion** into **Applications**.
3. Open **Applications** and double-click **Emberlight Companion**. The Mac shows a warning: click
   **Done** (or **OK**). Don't click Move to Bin.
4. Open **System Settings**, then **Privacy & Security**. Scroll down to the message about
   "Emberlight Companion" and click **Open Anyway**. Enter your Mac password if asked, then click
   **Open Anyway** once more.

You only do this once. After that it opens like any other app.

## The first steps

The same four steps as on Windows: the World of Warcraft folder (usually found by itself),
**Install** the addon, **Sign in** with Discord, and link your character. See
[INSTALL-WINDOWS.md](INSTALL-WINDOWS.md#3-the-four-first-steps).

The Mac may ask whether Emberlight Companion may use your keychain (where it keeps your sign-in).
Click **Always Allow**.

## If Play cannot open Battle.net

Emberlight checks for `Battle.net.app` in `/Applications` and your own `~/Applications`,
both directly and inside a `Battle.net` subfolder. It also asks macOS to find Battle.net by
name, so registered installations in other locations can work.

If Play reports an error, check that Battle.net opens from Finder. For a custom installation,
open it once from Finder so macOS can register it, then retry Play. The error includes macOS's
diagnostic details if opening still fails; you can start the game directly from Battle.net in
the meantime. For the Forever beta, Emberlight opens Battle.net on the beta; press Play there.

Opening Battle.net does not mean WoW has started. Emberlight keeps its window available and
only shows **In game** once it detects the WoW client. If Battle.net needs to update WoW,
finish the update and press Play in Battle.net; Emberlight will detect the game when it starts.

## Removing it

Quit it from the menu bar icon, then drag **Emberlight Companion** from Applications to the Bin.
