import { invoke } from "@tauri-apps/api/core";

export interface Notice {
  scope: string;
  id: string;
  owner: string;
  author: string;
  revision: number;
  created: number;
  expires: number;
  start: number;
  category: number;
  cancelled: boolean;
  title: string;
  location: string;
  body: string;
}

export interface Settings {
  wowRoot: string | null;
  flavor: string;
  server: string;
  memberName: string | null;
  discordId: string | null;
  autoUpdateAddon: boolean;
  keepInTray: boolean;
}

export interface WowStatus {
  root: string | null;
  problem: string | null;
  flavors: string[];
  emberlight: string | null;
  accounts: string[];
  gameRunning: boolean;
  /** The game programs still running. */
  running: string[];
}

export interface SyncReport {
  at: number;
  uploaded: number;
  stored: number;
  rejected: string[];
  downloaded: number | null;
  note: string | null;
  error: string | null;
}

export interface AddonStatus {
  installed: string | null;
  previous: string | null;
}

export interface AddonCheck {
  at: number;
  message: string;
  error: boolean;
  kind: "current" | "available" | "installed" | "restored" | "unpublished" | "failed" | "";
  /** The guild's newest published version, when known. */
  latest: string | null;
}

export interface Overview {
  settings: Settings;
  signedIn: boolean;
  wow: WowStatus;
  addon: AddonStatus;
  lastAddonCheck: AddonCheck | null;
  notices: Notice[];
  archiveWritten: number | null;
  lastSync: SyncReport | null;
  watching: boolean;
  launcherVersion: string;
}

export interface LauncherUpdate {
  version: string;
  notes: string | null;
}

export interface Claim {
  id: number;
  name: string;
  status: "pending" | "verified" | "refused";
  method: string | null;
  createdAt: number;
}

export interface Announcement {
  id: string;
  author: string;
  content: string;
  createdAt: number;
  editedAt: number;
  url: string;
}

/** An event from the server (`GET /v1/events`): official, or a member's adventure. */
export interface GuildEvent {
  scope: string;
  id: string;
  kind: "official" | "expedition" | "help" | "rp";
  title: string;
  location: string | null;
  body: string;
  start: number;
  expires: number;
  author: string;
  authorName: string | null;
  /** The signed-in member's own answers (empty on older servers). */
  ownReplies?: { response: string }[];
}

const KIND_CATEGORY: Record<GuildEvent["kind"], number> = { expedition: 1, help: 2, rp: 3, official: 4 };

/** Shown with the same rows as the events read from the game's synced file. */
export const eventAsNotice = (e: GuildEvent): Notice => ({
  scope: e.scope,
  id: e.id,
  owner: "",
  author: e.author,
  revision: 0,
  created: 0,
  expires: e.expires,
  start: e.start,
  category: KIND_CATEGORY[e.kind] ?? 0,
  cancelled: false,
  title: e.title,
  location: e.location ?? "",
  body: e.body,
});

export interface CharactersView {
  realm: string;
  realms: string[];
  mine: Claim[];
  found: { firstName: string; surname: string | null; name: string; realm: string }[];
}

export const inTauri = "__TAURI_INTERNALS__" in window;

/** The guild's server (store.rs DEFAULT_SERVER). */
export const DEFAULT_SERVER = "https://emberlightrp.com";
/** The guild website, on the same address as its server. */
export const WEBSITE = DEFAULT_SERVER;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!inTauri && import.meta.env.DEV) {
    const mock = await import("./dev-mock");
    return mock.handle(cmd, args) as Promise<T>;
  }
  return invoke<T>(cmd, args);
}

export const api = {
  overview: () => call<Overview>("overview"),
  saveSettings: (wowRoot: string | null, flavor: string, server: string) => call<Overview>("save_settings", { wowRoot, flavor, server }),
  signIn: (token: string) => call<Overview>("sign_in", { token }),
  signInDiscord: () => call<Overview>("sign_in_discord"),
  cancelSignIn: () => call<void>("cancel_sign_in"),
  signOut: () => call<Overview>("sign_out"),
  refreshAccount: () => call<Overview>("refresh_account"),
  characters: () => call<CharactersView>("characters"),
  announcements: () => call<Announcement[]>("announcements"),
  guildEvents: (kind: "official" | "member") => call<GuildEvent[]>("guild_events", { kind }),
  openLink: (url: string) => call<void>("open_link", { url }),
  syncNow: () => call<Overview>("sync_now"),
  updateAddon: () => call<Overview>("update_addon"),
  checkAddon: () => call<Overview>("check_addon"),
  setAutoUpdateAddon: (on: boolean) => call<Overview>("set_auto_update_addon", { on }),
  setKeepInTray: (on: boolean) => call<Overview>("set_keep_in_tray", { on }),
  restoreAddon: () => call<Overview>("restore_addon"),
  launcherUpdate: () => call<LauncherUpdate | null>("launcher_update"),
  installLauncherUpdate: () => call<void>("install_launcher_update"),
  play: () => call<Overview>("play"),
  closeWindow: () => call<void>("close_window"),
};

/** Links always open in the member's own browser, never inside the Companion. */
export function openInBrowser(url: string) {
  if (inTauri) api.openLink(url).catch(() => undefined);
  else window.open(url, "_blank", "noopener");
}

// The words the addon shows since 0.7 (Emberlight/Core/Bootstrap.lua); only the number travels.
export const CATEGORIES = ["", "Journey", "Call for aid", "Gathering", "Guild event"];

export const FLAVOR_NAMES: Record<string, string> = {
  _retail_: "Retail",
  _classic_beta_: "Forever beta",
  _classic_: "Classic",
  _classic_era_: "Classic Era",
  _ptr_: "Test realm",
  _xptr_: "Test realm",
  _beta_: "Beta",
};

export const flavorName = (f: string) => FLAVOR_NAMES[f] ?? f.replace(/^_|_$/g, "").replace(/_/g, " ");
