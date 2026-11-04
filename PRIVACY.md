# What Emberlight reads, sends and keeps

Plain answers, with links to the code that does each thing. "The app" means Emberlight Companion.

## The addon

World of Warcraft addons can't reach the internet. The Emberlight addon only talks to other guild
members' Emberlight addons through the game's own addon channel, and keeps its data in the game's
normal saved file (`WTF/Account/<account>/SavedVariables/Emberlight.lua`). That's all.

## The app: what it reads on your computer

| What | Why | Sent anywhere? |
|---|---|---|
| Where WoW and Battle.net are installed (Blizzard's own registry entries, then the usual folders) | To find the game and start its client directly, with Battle.net as a fallback ([`paths.rs`](sync/src/paths.rs)) | No |
| The addon's saved file, `Emberlight.lua`, for each WoW account in the game folder | To pick up what you posted in game | Only your own posts (see below) |
| The names of the character folders the game makes under `WTF/Account` | To suggest characters you might link on the website | **No**, shown in the app only |
| Battle.net’s `.flavor.info` and `.build.info`, and client filenames in the chosen game folder | To recognise Forever, show its version and find the game client | No |
| The installed addon's version, and `Emberlight_Data` | To offer updates and show events | No |
| Which programs are running, every 3 seconds, on your computer only | To notice WoW opening and closing, so it never changes addon files while you play and syncs after you log out ([`wow.rs`](sync/src/wow.rs)) | No |

It never writes to your saved files. The only game folders it changes are
`Interface/AddOns/Emberlight` (when it installs an addon update; the previous version is kept so you
can go back) and `Interface/AddOns/Emberlight_Data`.

## The app: what it sends, where and when

**Everything goes to one place: the guild's website, `https://emberlightrp.com`.** Nothing else, over
HTTPS only ([`api.rs`](sync/src/api.rs)). The app's window is locked so it can't contact anything
itself ([`tauri.conf.json`](launcher/src-tauri/tauri.conf.json), the `csp` line). There is no
tracking, analytics or crash reporting.

| When | What |
|---|---|
| You sign in | Your browser opens the website, which sends you to Discord. Discord is asked only for your name and id and your roles on the Emberlight server. The website throws Discord's access token away straight after. The app never sees your Discord or Battle.net password. |
| A sync: when the app opens (unless it synced a few minutes ago), when you press Play or Sync now, and after you log out of WoW | Uploads the posts and replies **your own linked characters** wrote in the addon ([`flow.rs`](sync/src/flow.rs)). If you're an officer, also the posts you removed in game. Also up to 50 "verification sightings" from the last week: when another guild member types `/emberlight verify CODE` to prove a character is theirs, your addon notes that character's name and code, and the app passes it on so officers can confirm it. Then it downloads the guild's posts. |
| About every 3 minutes while you are signed in, and when the window returns if its information is older than 3 minutes | Asks for guild events, announcements and your linked characters. Overlapping refreshes are combined. |
| When the app opens and every 4 hours | Asks whether there's a newer addon or app. No sign-in and nothing about you is sent. |
| You sign out | Ends your session on the website. |

## What's kept

**On your computer:**
- A settings file in the app's folder (`%APPDATA%\org.emberlight.launcher\settings.json` on
  Windows): your WoW folder, game version, your name in the Emberlight Discord and your Discord id,
  and the result of the last sync.
- Window size and position, alert/reminder preferences, and which announcements you have read. Read marks and reminder history are kept separately for each Discord account, on this computer only. They are never sent to the guild or counted as activity.
- If you choose Start with Windows, a normal startup registration is added. It is off by default and can be switched off in Settings.
- Your sign-in, in **Windows Credential Manager** (the Mac keychain on a Mac) under "Emberlight
  Launcher". It stops working after 14 days, or when you sign out.

**On the guild's website:** your Discord id and name, your guild roles, a scrambled (hashed) copy
of your sign-in so the real one is never stored, one "signed in" line per day, and whatever you
post. The website doesn't store IP addresses; like any website, its host (Cloudflare) sees them
in its normal logs.

**Activity.** The guild's officers can see when each member last visited the website, and, from the
guild's Discord bot, when they last wrote a message anywhere in the Discord server (never the
text) and were last online there. Using the app, the sync tool or the addon never counts as
activity, and nothing from the game is used.

## Things you can switch off

In the app's Settings: installing addon updates by itself ("Update the addon by itself"), Windows
new-event alerts, personal event reminders (15 minutes or one hour), starting quietly with Windows, and staying in the tray (beside the clock) when you close the window. The app
never installs a new version of itself on its own: it offers **Restart to update** and waits for
you. The bug-report button copies a limited summary to your clipboard, never sends it. Account names, Discord IDs, tokens, personal folder paths and identifying error details are excluded.

If you quit the app from the tray, it does nothing until you open it again or your next sign-in if you chose Start with Windows.

## Removing it

Uninstall "Emberlight Companion" from Windows Settings, Apps. To remove the addon, delete the
`Emberlight` and `Emberlight_Data` folders from `Interface/AddOns`.
