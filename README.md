# Emberlight Companion and the Emberlight addon

This is the source code of everything the Emberlight guild asks members to install: the
**Emberlight addon** for World of Warcraft, and **Emberlight Companion**, an optional desktop app.
It's public so that anyone can read exactly what they do before installing them.

- **Download for Windows:** [Emberlight-Companion-Setup.exe](https://github.com/rsamuelsen/emberlight-app/releases/latest/download/Emberlight-Companion-Setup.exe)
  ([how to install](INSTALL-WINDOWS.md))
- **Just the addon, for any computer:** [Emberlight-addon.zip](https://github.com/rsamuelsen/emberlight-app/releases/latest/download/Emberlight-addon.zip)
  ([how to install](INSTALL-WINDOWS.md#just-the-addon))
- **Mac (preview, not tested with the game yet):** [Emberlight-Companion-Mac.dmg](https://github.com/rsamuelsen/emberlight-app/releases/latest/download/Emberlight-Companion-Mac.dmg)
  ([how to install](INSTALL-MAC.md))
- **What it reads and sends:** [PRIVACY.md](PRIVACY.md)

All downloads are built from this code by GitHub itself (see "Where the downloads come from" below).

## What's what

| Folder | What it is |
|---|---|
| [`Emberlight/`](Emberlight) | The in-game addon (Lua). Guild events, adventures and replies, shared with other guild members through the game's addon channel. Works fully on its own. |
| [`launcher/`](launcher) | Emberlight Companion, the desktop app (Tauri: Rust with a React window). Shows guild events and announcements, starts WoW through Battle.net, keeps the addon up to date. |
| [`sync/`](sync) | The part of the app that reads the addon's saved file after you log out, uploads your own posts to the guild's website, and writes the guild's posts into a small data addon, `Emberlight_Data`. Also a command-line tool. |

## Do I need the app?

No. The addon does everything in game by itself. The app adds one thing the game can't: you see
posts made while you were offline, because it fetches them from the guild's website before you
play. It also installs and updates the addon for you.

## Where the downloads come from

Each release is built by the [Release](.github/workflows/release.yml) workflow on GitHub's own
computers, straight from the code in this repository, and every download has a GitHub
attestation that proves it. With the GitHub command-line tool you can check a file yourself:

```
gh attestation verify Emberlight-Companion-Setup.exe --repo rsamuelsen/emberlight-app
```

`SHA256SUMS.txt` in each release lists the files' checksums.

The app's own updates and the addon updates it installs are signed. The app checks those
signatures against keys built into it before it installs anything.

## Building it yourself

You need Rust (stable) and Node 24.

```
cd launcher
npm ci
npx tauri build --config src-tauri/tauri.unsigned.conf.json
```

`cargo test` in `sync/` runs the sync tool's own checks. The guild's full test suite isn't
published, because its test data uses guild members' character names.

## Contributing and questions

This repository is a published copy: the guild develops in its own repository and copies each
version here, so pull requests here can't be merged directly. Questions and concerns are welcome
on the Emberlight Discord.

## Licence

The code is under the [MIT licence](LICENSE). The Emberlight name, crest and artwork are not
covered by it. World of Warcraft and Battle.net are trademarks of Blizzard Entertainment;
Emberlight is a fan project and is not made by or connected to Blizzard.
