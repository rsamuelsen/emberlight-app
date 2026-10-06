import type { Claim, LauncherUpdate, Overview } from "./api";

interface Props {
  overview: Overview;
  busy: boolean;
  onInstall: () => void;
  onSettings: () => void;
  launcherUpdate: LauncherUpdate | null;
  updatingLauncher: boolean;
  onUpdateLauncher: () => void;
}

export function Mark({ status }: { status: Claim["status"] }) {
  if (status === "verified") {
    return (
      <svg className="mark" viewBox="0 0 20 20" aria-hidden="true">
        <circle cx="10" cy="10" r="9" fill="#23408e" stroke="#c99a3f" strokeOpacity="0.5" />
        <path d="M10 3.5 Q10.8 9.2 16.5 10 Q10.8 10.8 10 16.5 Q9.2 10.8 3.5 10 Q9.2 9.2 10 3.5 Z" fill="#e3c170" />
      </svg>
    );
  }
  return <span className={`mark mark-${status}`} aria-hidden="true" />;
}

/** True when version `a` is newer than `b` (dotted numbers, as the release check compares them). */
export function isNewer(a: string, b: string) {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0);
  }
  return false;
}

/** The addon's and the Companion's versions, beside Play. Quiet when both are current; outlined in
 *  gold, with one button, when a newer version is ready. */
export function StatusCard({ overview, busy, onInstall, onSettings, launcherUpdate, updatingLauncher, onUpdateLauncher }: Props) {
  const { addon, lastAddonCheck, wow } = overview;
  const gameFound = !!wow.root && !wow.problem;
  const latest = lastAddonCheck?.latest ?? null;
  const addonNew = !!addon.installed && !!latest && isNewer(latest, addon.installed);
  const closeFirst = wow.gameRunning || overview.watching;

  const addonNote = !gameFound
    ? "No game folder"
    : !addon.installed
      ? closeFirst && gameFound
        ? "Close the game"
        : "Not installed"
      : addonNew
        ? closeFirst
          ? "Close the game"
          : "New version"
        : lastAddonCheck?.error
          ? "Could not check"
          : lastAddonCheck?.kind === "unpublished"
            ? "No guild release yet"
            : lastAddonCheck
              ? "Up to date"
              : "";

  return (
    <section className={`card versions${addonNew || launcherUpdate ? " is-attention" : ""}`} aria-label="Versions">
      <div className={`card-row version-row${addonNew || (gameFound && !addon.installed) ? " is-new" : ""}`}>
        <span className="card-label">Addon</span>
        <span className="card-value" title={addonNew ? `Installed: ${addon.installed}` : undefined}>
          {addon.installed && <strong>{addonNew ? latest : addon.installed}</strong>}
        </span>
        <span className={`card-note version-note${lastAddonCheck?.error && !addonNew ? " is-problem" : ""}`} title={lastAddonCheck?.message}>
          {addonNote}
        </span>
        {!gameFound ? (
          <button className="version-action" onClick={onSettings}>
            Choose folder
          </button>
        ) : (
          (addonNew || !addon.installed) && (
            <button className="version-action is-primary" disabled={busy || closeFirst} onClick={onInstall}>
              {addon.installed ? "Update" : "Install"}
            </button>
          )
        )}
      </div>

      <div className={`card-row version-row${launcherUpdate ? " is-new" : ""}`}>
        <span className="card-label">Companion</span>
        <span className="card-value" title={launcherUpdate ? `Installed: ${overview.launcherVersion}` : undefined}>
          <strong>{launcherUpdate ? launcherUpdate.version : overview.launcherVersion}</strong>
        </span>
        <span className="card-note version-note">
          {launcherUpdate ? (updatingLauncher ? "Updating" : overview.watching ? "Close the game" : "New version") : "Up to date"}
        </span>
        {launcherUpdate && (
          <button className="version-action is-primary" disabled={updatingLauncher || overview.watching} onClick={onUpdateLauncher}>
            Restart to update
          </button>
        )}
      </div>
    </section>
  );
}
