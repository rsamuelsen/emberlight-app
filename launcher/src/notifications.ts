import { api, type GuildEvent, inTauri } from "./api";
import { serverWhen } from "./events";

export interface NotificationSettings { newEvents: boolean; myReminders: boolean; reminderMinutes: 15 | 60; }
export function notificationSettings(): NotificationSettings {
  try {
    const old = localStorage.getItem("emberlight.notifications") !== "off";
    const data = JSON.parse(localStorage.getItem("emberlight.notification-settings") ?? "null");
    return { newEvents: typeof data?.newEvents === "boolean" ? data.newEvents : old, myReminders: typeof data?.myReminders === "boolean" ? data.myReminders : old, reminderMinutes: data?.reminderMinutes === 15 ? 15 : 60 };
  } catch { return { newEvents: true, myReminders: true, reminderMinutes: 60 }; }
}
export function setNotificationSettings(settings: NotificationSettings) {
  try { localStorage.setItem("emberlight.notification-settings", JSON.stringify(settings)); } catch { /* This preference may not survive a restart. */ }
  window.dispatchEvent(new Event("emberlight-notification-settings"));
}
const load = (key: string): string[] | null => {
  try { const v = JSON.parse(localStorage.getItem(key) ?? "null"); return Array.isArray(v) ? v.filter(x => typeof x === "string") : null; } catch { return null; }
};
const save = (key: string, items: string[]) => { try { localStorage.setItem(key, JSON.stringify(items.slice(-300))); } catch { /* No persistent deduplication if storage is unavailable. */ } };
let session = 0;
let pending = false;
export const clearReminderSession = () => { session++; pending = false; };

/** Per-account deduplication. Signing out invalidates every pending reminder callback. */
export async function checkNotifications(events: GuildEvent[], now: number, account: string | null) {
  if (!account || pending) return;
  const generation = session;
  pending = true;
  const prefs = notificationSettings();
  const key = (e: GuildEvent) => `${e.scope}/${e.id}/${e.start}`;
  const seenKey = `emberlight.seen-events.${account}`;
  const remindedKey = `emberlight.reminded-events.${account}`;
  const seen = load(seenKey);
  const reminded = load(remindedKey) ?? [];
  const send = async (title: string, e: GuildEvent) => {
    if (session !== generation) return false;
    try { if (inTauri) await api.notify(title, serverWhen(e.start, true) + (e.location ? ` · ${e.location}` : "")); return session === generation; } catch { return false; }
  };
  try {
    if (seen && prefs.newEvents) for (const e of events) {
      if (session !== generation) return;
      if (e.start > now && !seen.includes(key(e))) await send(`New guild event: ${e.title}`, e);
    }
    if (session !== generation) return;
    save(seenKey, [...(seen ?? []).filter(k => !events.some(e => key(e) === k)), ...events.map(key)]);
    if (prefs.myReminders) for (const e of events) {
      if (session !== generation) return;
      if (e.ownReplies?.some(r => r.response === "I will join") && e.start > now && e.start - now <= prefs.reminderMinutes * 60 && !reminded.includes(key(e))) {
        if (await send(`Starting soon: ${e.title}`, e)) reminded.push(key(e));
      }
    }
    if (session === generation) save(remindedKey, reminded);
  } finally { if (session === generation) pending = false; }
}
