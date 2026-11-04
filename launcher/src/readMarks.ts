import type { Announcement } from "./api";
const key = (account: string) => `emberlight.read-announcements.${account}`;
const load = (account: string): Record<string, number> => {
  try { const data = JSON.parse(localStorage.getItem(key(account)) ?? "{}"); return data && typeof data === "object" && !Array.isArray(data) ? data : {}; } catch { return {}; }
};
export const announcementUnread = (account: string | null, item: Announcement) => !!account && load(account)[item.id] !== item.editedAt;
export function markAnnouncementRead(account: string | null, item: Announcement): boolean {
  if (!account || !announcementUnread(account, item)) return false;
  try { const marks = load(account); delete marks[item.id]; marks[item.id] = item.editedAt; localStorage.setItem(key(account), JSON.stringify(Object.fromEntries(Object.entries(marks).slice(-500)))); return true; } catch { return false; }
}
