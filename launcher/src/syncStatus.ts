import type { SyncReport } from "./api";

const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** What was sent, in words: "2 notices, 1 reply and 3 profession updates". */
export function sentList(report: SyncReport) {
  const s = report.sent ?? { notices: 0, replies: 0, removals: 0, professions: 0 };
  const parts = [
    s.notices && count(s.notices, "notice", "notices"),
    s.replies && count(s.replies, "reply", "replies"),
    s.removals && count(s.removals, "removal", "removals"),
    s.professions && count(s.professions, "profession update", "profession updates"),
  ].filter(Boolean) as string[];
  // A report saved by an older Companion has only the total.
  if (!parts.length && report.stored > 0) parts.push(count(report.stored, "update", "updates"));
  return parts.length > 1 ? `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}` : parts[0] ?? "";
}

export function syncSummary(report: SyncReport | null) {
  if (!report) return "Not synced yet.";
  if (report.error) return "Could not finish syncing.";
  const list = sentList(report);
  // No saved Emberlight data at all in this game folder: the addon never ran there, so nothing
  // can ever be sent. Say so, rather than a sync that looks fine (8 November 2026).
  const sent = list
    ? `Sent ${list} to the guild website. `
    : report.addonFiles === 0
      ? "Nothing to send: the Emberlight addon has not saved anything in this game folder yet. Check that the addon is turned on in game and that Settings shows WoW: Forever. "
      : "Nothing new to send. ";
  const ready = report.downloaded !== null
    ? "Downloaded the latest guild events. You'll see them in game next time you log in."
    : "New guild events will be added after the game closes.";
  return sent + ready;
}
export function syncRecovery(report: SyncReport | null): "signin" | "characters" | "retry" {
  const text = [report?.error, ...(report?.rejected ?? [])].join(" ").toLowerCase();
  if (/sign.?in|session|unauthori|401|expired.*token/.test(text)) return "signin";
  if (/character|verif|not.*yours|ownership/.test(text)) return "characters";
  return "retry";
}
