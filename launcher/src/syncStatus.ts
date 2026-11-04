import type { SyncReport } from "./api";

export function syncSummary(report: SyncReport | null) {
  if (!report) return "Not synced yet.";
  if (report.error) return "Could not finish syncing.";
  const sent = report.stored > 0 ? `Sent ${report.stored} update${report.stored === 1 ? "" : "s"} to the guild website. ` : "";
  const ready = report.downloaded !== null ? "Guild events are ready for the game." : "New guild events will be added after the game closes.";
  return sent + ready;
}
export function syncRecovery(report: SyncReport | null): "signin" | "characters" | "retry" {
  const text = [report?.error, ...(report?.rejected ?? [])].join(" ").toLowerCase();
  if (/sign.?in|session|unauthori|401|expired.*token/.test(text)) return "signin";
  if (/character|verif|not.*yours|ownership/.test(text)) return "characters";
  return "retry";
}
