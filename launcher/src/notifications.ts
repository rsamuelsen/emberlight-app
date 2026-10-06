import { invoke } from "@tauri-apps/api/core";
import { inTauri, type GuildEvent } from "./api";
import { fmtLong } from "./events";

// Windows notifications while the Companion is running: a new guild event, and a reminder an
// hour before one the member said "I will join" to. What was already announced is remembered in
// this app's own storage, so nothing is announced twice.
const ON = "emberlight.notifications";
const SEEN = "emberlight.seen-events";
const REMINDED = "emberlight.reminded-events";
const REMIND_BEFORE = 3600;

const load = (key: string): string[] | null => {
  try {
    const v = JSON.parse(localStorage.getItem(key) ?? "null");
    return Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
};
const save = (key: string, ids: string[]) => {
  try {
    localStorage.setItem(key, JSON.stringify(ids.slice(-300)));
  } catch {
    // Without storage the next check may announce again; nothing breaks.
  }
};

export const notificationsOn = () => {
  try {
    return localStorage.getItem(ON) !== "off";
  } catch {
    return true;
  }
};
export const setNotificationsOn = (on: boolean) => {
  try {
    localStorage.setItem(ON, on ? "on" : "off");
  } catch {
    // Kept for this session only.
  }
};

const send = (title: string, body: string) => {
  if (inTauri) invoke("notify", { title, body }).catch(() => undefined);
};

/** Called whenever the official events are read again, and every minute. */
export function checkNotifications(events: GuildEvent[], now: number) {
  const key = (e: GuildEvent) => `${e.scope}/${e.id}`;
  const seen = load(SEEN);
  // The first read only learns what is there: an install never opens with a burst of old news.
  if (seen) {
    for (const e of events) {
      if (!seen.includes(key(e)) && e.start > now && notificationsOn()) send(`New guild event: ${e.title}`, `${fmtLong.format(e.start * 1000)}${e.location ? ` · ${e.location}` : ""}`);
    }
  }
  save(SEEN, [...(seen ?? []).filter((k) => !events.some((e) => key(e) === k)), ...events.map(key)]);

  const reminded = load(REMINDED) ?? [];
  const due = events.filter(
    (e) => e.ownReplies?.some((r) => r.response === "I will join") && e.start > now && e.start - now <= REMIND_BEFORE && !reminded.includes(key(e)),
  );
  for (const e of due) if (notificationsOn()) send(`Starting soon: ${e.title}`, `${fmtLong.format(e.start * 1000)}${e.location ? ` · ${e.location}` : ""}`);
  if (due.length) save(REMINDED, [...reminded, ...due.map(key)]);
}
