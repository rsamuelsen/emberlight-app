import { FLAVOR_NAMES, type Overview } from "./api";
// Copy a whitelist, never raw diagnostics. Server errors can contain names, tokens or paths.
function errorKind(error: string | null | undefined) {
  if (!error) return "None";
  if (/sign.?in|session|401|unauthori/i.test(error)) return "Sign-in or session problem";
  if (/character|verif|owner/i.test(error)) return "Character verification problem";
  if (/signature|signing/i.test(error)) return "Signature verification problem";
  if (/network|connect|reach|timeout|request/i.test(error)) return "Connection problem";
  if (/game.*running|close.*warcraft/i.test(error)) return "Game is running";
  if (/folder|directory|file|path/i.test(error)) return "Game folder or file problem";
  return "Other error (identifying details left out)";
}
export function bugReport(o: Overview) {
  const root = o.wow.root ?? o.settings.wowRoot;
  const folder = !root ? "Not found" : /^(?:[a-z]:\\Program Files(?: \(x86\))?\\World of Warcraft|\/Applications\/World of Warcraft)\/?$/i.test(root.replace(/\\+$/g, "")) ? root : "Custom location (personal path left out)";
  const version = (v: string | null | undefined) => v && /^[\d., ]+$/.test(v) ? v : "Unknown";
  const game = o.settings.flavor === "_forever_" || o.wow.forever?.includes(o.settings.flavor) ? "WoW: Forever" : FLAVOR_NAMES[o.settings.flavor] ?? "Unknown";
  return ["Emberlight Companion bug report", `Companion: ${version(o.launcherVersion)}`, `Addon: ${version(o.addon.installed)}`, `Game: ${game}`, `Game build: ${version(o.wow.version)}`, `Game folder: ${folder}`, `Last sync: ${o.lastSync ? new Date(o.lastSync.at * 1000).toISOString() : "Never"}`, `Sync error: ${errorKind(o.lastSync?.error)}`, `Addon error: ${errorKind(o.lastAddonCheck?.error ? o.lastAddonCheck.message : null)}`].join("\n");
}
