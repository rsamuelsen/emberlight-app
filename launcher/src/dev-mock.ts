// Browser preview only (vite dev without Tauri). Never bundled into the app: api.ts loads it
// behind import.meta.env.DEV. Notices come from the shared test fixtures, moved to the present.
// Preview address options: ?state=fresh | empty | error | ingame | syncing | update, ?view=ledger |
// characters | news | setup, ?page=events | news, and ?still to switch off animation.
import fixture from "../../shared/fixtures/expected/alice-guild.notices.json";
import type { Announcement, CharactersView, Notice, Overview } from "./api";

const now = () => Math.floor(Date.now() / 1000);
const shift = now() - 1800000000;
const fixtureNotices: Notice[] = fixture.notices.map((n) => ({ ...n, created: n.created + shift, expires: n.expires + shift, start: n.start + shift }));
// Two extra official events so the agenda layout can be checked in the preview.
const official = fixtureNotices.find((n) => n.category === 4)!;
const sample: Notice[] = [
  ...fixtureNotices,
  { ...official, id: "preview-2", title: "Officer meeting", location: "Stormwind Keep", body: "Planning the autumn season.", start: official.start + 86400 * 2 + 3600, expires: official.expires + 86400 * 3 },
  { ...official, id: "preview-3", title: "Road to Darkshire", location: "Duskwood", body: "Escort for the new members. Bring torches.", start: official.start + 86400 * 5, expires: official.expires + 86400 * 6 },
  // Members' adventures: one under way, one tonight, one secret place.
  { ...official, id: "preview-4", category: 3, title: "Stories by the fire", location: "Lion's Pride Inn", body: "Come as you are.", start: now() - 1200, expires: now() + 2400 },
  { ...official, id: "preview-5", category: 1, title: "Into the Redridge hills", location: "Lakeshire", body: "A short ride east. Mounts ready by the bridge.", start: now() + 3 * 3600, expires: now() + 6 * 3600 },
  { ...official, id: "preview-6", category: 2, title: "Lost caravan", location: "", body: "Help us find the wagons before dark.", start: now() + 86400 + 3600, expires: now() + 86400 + 4 * 3600 },
];
const params = new URLSearchParams(location.search);
const view = params.get("state");
if (params.has("still")) {
  const style = document.createElement("style");
  style.textContent = "*,*::before,*::after{animation-play-state:paused!important;animation-delay:-0.6s!important;transition:none!important}";
  document.head.append(style);
}
export const previewView = params.get("view");
export const previewPage = params.get("page");

let state: Overview = {
  settings: { wowRoot: "C:\\Program Files (x86)\\World of Warcraft", flavor: "_retail_", server: "http://127.0.0.1:8787", memberName: "Wayfarer", discordId: "123456789012345678", autoUpdateAddon: true, keepInTray: true },
  signedIn: true,
  wow: { root: "C:\\Program Files (x86)\\World of Warcraft", problem: null, flavors: ["_retail_", "_classic_"], emberlight: "120100", accounts: ["WOW1"], gameRunning: false, running: [] },
  addon: { installed: "0.6.0", previous: "0.5.0" },
  lastAddonCheck: { at: now() - 600, message: "Emberlight 0.6.0 is up to date.", error: false, kind: "current", latest: "0.6.0" },
  notices: sample,
  archiveWritten: now() - 600,
  lastSync: { at: now() - 600, uploaded: 2, stored: 0, rejected: [], downloaded: 3, note: null, error: null },
  watching: false,
  launcherVersion: "0.1.0",
};

if (view === "fresh") {
  state = { ...state, signedIn: false, notices: [], archiveWritten: null, lastSync: null, addon: { installed: null, previous: null }, lastAddonCheck: null, settings: { ...state.settings, wowRoot: null, server: "", memberName: null }, wow: { ...state.wow, root: null, problem: "World of Warcraft was not found in the usual place.", flavors: [], emberlight: null, accounts: [] } };
}
if (view === "empty") state = { ...state, notices: [] };
if (view === "error") state = { ...state, lastSync: { ...state.lastSync!, error: "Could not reach the Emberlight server." } };
if (view === "ingame") state = { ...state, watching: true, wow: { ...state.wow, gameRunning: true, running: ["wow.exe"] } };
// ?state=update: a newer addon and a newer Companion are both waiting (auto-update switched off).
if (view === "update") {
  state = {
    ...state,
    settings: { ...state.settings, autoUpdateAddon: false },
    lastAddonCheck: { at: now() - 60, message: "Emberlight 0.6.1 is ready to install.", error: false, kind: "available", latest: "0.6.1" },
  };
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
let cancelled = false;

// Preview-only text to exercise the Discord formatting; never part of the app.
let announcements: Announcement[] = [
  {
    id: "1",
    author: "Wayfarer",
    content: `@everyone \n# Autumn muster at Goldshire\nAll members are called to the **Lion's Pride Inn** on <t:${now() + 3 * 86400}:F>.\n- Bring your tabard\n- New members welcome\n> Light the lanterns early.\nDetails on the [guild forum](https://example.com/forum).`,
    createdAt: now() - 7200,
    editedAt: now() - 7200,
    url: "https://discord.com/channels/1/2/1",
  },
  {
    id: "2",
    author: "Keeper",
    content: "## Launcher testing\nThe sync launcher is being tried by officers this week. Report anything odd in *#bugs*.",
    createdAt: now() - 3 * 86400,
    editedAt: now() - 3 * 86400,
    url: "https://discord.com/channels/1/2/2",
  },
];

let characters: CharactersView = {
  realm: "TestRealm",
  realms: ["TestRealm"],
  mine: [
    { id: 1, name: "Alice", status: "verified", method: "officer", createdAt: now() - 86400 },
    { id: 2, name: "Alice Example", status: "pending", method: null, createdAt: now() - 3600 },
  ],
  found: [{ firstName: "Bob", surname: null, name: "Bob", realm: "TestRealm" }],
};

if (view === "fresh") characters = { ...characters, mine: [], found: [{ firstName: "Bob", surname: null, name: "Bob", realm: "TestRealm" }] };

// ?state=showcase: tidy example content for screenshots on the website (marked there as example).
if (view === "showcase") {
  const at = (days: number, hour: number, minute = 0) => {
    const d = new Date();
    d.setDate(d.getDate() + days);
    d.setHours(hour, minute, 0, 0);
    return Math.floor(d.getTime() / 1000);
  };
  const event = (id: string, title: string, location: string, body: string, start: number, author: string): Notice => ({
    scope: "3:123", id: `showcase:${id}`, owner: `${author.toLowerCase()}-realm`, author: `${author}-Realm`, revision: 1,
    created: now() - 86400, expires: start + 4 * 3600, start, category: 4, cancelled: false, title, location, body,
  });
  state = {
    ...state,
    notices: [
      event("1", "Autumn muster", "Lion's Pride Inn, Goldshire", "The first gathering of the season. Bring your tabard and a story from your travels.\nNew faces are very welcome.", at(3, 20), "Alice"),
      event("2", "Road to Darkshire", "Duskwood", "An escort for the caravan through the woods. Torches and steady nerves required.", at(5, 19, 30), "Bob"),
      event("3", "Lanterns on the lake", "Stormwind Harbour", "A quiet evening by the water to remember absent friends.", at(8, 21), "Alice"),
    ],
  };
  announcements = [
    { id: "s1", author: "Officers", content: "# Welcome, new adventurers\nThis week we welcome five new members. Say hello around the campfire and join the muster on Saturday.", createdAt: now() - 7200, editedAt: now() - 7200, url: "https://discord.com/channels/1/2/1" },
    { id: "s2", author: "Officers", content: "## The Chronicle is open\nOur first pages are written. Read about the founding night in the member portal.", createdAt: now() - 3 * 86400, editedAt: now() - 3 * 86400, url: "https://discord.com/channels/1/2/2" },
  ];
  characters = {
    ...characters,
    mine: [
      { id: 1, name: "Alice Example", status: "verified", method: "officer", createdAt: now() - 86400 * 20 },
      { id: 2, name: "Bob Example", status: "pending", method: null, createdAt: now() - 3600 },
    ],
    found: [],
  };
  // Synced a moment ago, so the preview does not start a sync while the screenshot is taken.
  state = { ...state, lastSync: { at: now() - 60, uploaded: 0, stored: 0, rejected: [], downloaded: 3, note: null, error: null } };
}

export async function handle(cmd: string, args?: Record<string, unknown>): Promise<unknown> {
  switch (cmd) {
    case "overview":
      return state;
    case "sync_now":
      await wait(view === "syncing" ? 1e9 : 2400);
      state = { ...state, lastSync: { at: now(), uploaded: 0, stored: 0, rejected: [], downloaded: state.notices.length, note: null, error: null } };
      return state;
    case "update_addon":
      await wait(1500);
    {
      const latest = state.lastAddonCheck?.latest ?? "0.6.0";
      const changed = state.addon.installed !== latest;
      state = {
        ...state,
        addon: { installed: latest, previous: changed ? state.addon.installed : state.addon.previous },
        lastAddonCheck: changed
          ? { at: now(), message: `Emberlight ${latest} installed. It takes effect the next time you log in.`, error: false, kind: "installed", latest }
          : { at: now(), message: `Emberlight ${latest} is up to date.`, error: false, kind: "current", latest },
      };
      return state;
    }
    case "check_addon":
      await wait(500);
      return state;
    case "set_keep_in_tray":
      state = { ...state, settings: { ...state.settings, keepInTray: !!args?.on } };
      return state;
    case "set_auto_update_addon":
      state = { ...state, settings: { ...state.settings, autoUpdateAddon: !!args?.on } };
      return state;
    case "restore_addon":
      await wait(800);
      if (!state.addon.previous) throw "There is no previous version to restore.";
      state = { ...state, addon: { installed: state.addon.previous, previous: null }, lastAddonCheck: { at: now(), message: `Emberlight ${state.addon.previous} is back in place.`, error: false, kind: "restored", latest: state.lastAddonCheck?.latest ?? null } };
      return state;
    case "launcher_update":
      await wait(600);
      return view === "update" ? { version: "0.2.0", notes: "A bigger window and a new Settings page." } : null;
    case "install_launcher_update":
      await wait(2000);
      throw "Preview only: the real app restarts into the new version here.";
    case "play":
      await wait(2000);
      state = { ...state, watching: true };
      return state;
    case "save_settings":
      state = { ...state, settings: { ...state.settings, wowRoot: (args?.wowRoot as string) ?? null, flavor: args?.flavor as string, server: args?.server as string } };
      if (args?.wowRoot) state = { ...state, wow: { ...state.wow, root: args.wowRoot as string, problem: null, flavors: ["_retail_", "_classic_"], accounts: ["WOW1"] } };
      return state;
    case "sign_in":
      await wait(800);
      if (String(args?.token).length < 32) throw "The session token is not valid.";
      state = { ...state, signedIn: true, settings: { ...state.settings, memberName: "Wayfarer" } };
      return state;
    case "sign_in_discord":
      await wait(2500);
      if (cancelled) {
        cancelled = false;
        throw "Sign-in was cancelled.";
      }
      state = { ...state, signedIn: true, settings: { ...state.settings, memberName: "Wayfarer" } };
      return state;
    case "cancel_sign_in":
      cancelled = true;
      return;
    case "announcements":
      await wait(400);
      return view === "fresh" ? [] : announcements;
    case "guild_events":
      await wait(400);
      return state.notices
        .filter((n) => (args?.kind === "official" ? n.category === 4 : n.category !== 4) && !n.cancelled)
        .sort((a, b) => a.start - b.start)
        .map((n) => ({ scope: n.scope, id: n.id, kind: (["", "expedition", "help", "rp", "official"] as const)[n.category], title: n.title, location: n.location || null, body: n.body, start: n.start, expires: n.expires, author: n.author, authorName: n.author.split("-")[0] }));
    case "open_link":
      return;
    case "characters":
      await wait(300);
      return characters;
    case "sign_out":
      state = { ...state, signedIn: false, settings: { ...state.settings, memberName: null, discordId: null } };
      return state;
    case "refresh_account":
      await wait(300);
      state = { ...state, settings: { ...state.settings, memberName: "Wayfarer", discordId: "123456789012345678" } };
      return state;
    case "close_window":
      return;
  }
  throw `unknown command ${cmd}`;
}
