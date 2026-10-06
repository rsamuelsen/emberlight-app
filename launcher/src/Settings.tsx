import { useState } from "react";
import { api, DEFAULT_SERVER, flavorName, inTauri, type LauncherUpdate, type Overview } from "./api";
import { notificationsOn, setNotificationsOn } from "./notifications";

const message = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : "Something went wrong.");

interface Props {
  overview: Overview;
  onUpdate: (o: Overview) => void;
  launcherUpdate: LauncherUpdate | null;
  onLauncherUpdate: (u: LauncherUpdate | null) => void;
}

/** One page: Discord, the game, the addon and the Companion itself. Characters have their own tab. */
export function Settings({ overview, onUpdate, launcherUpdate, onLauncherUpdate }: Props) {
  const { settings, wow, signedIn, addon, lastAddonCheck } = overview;
  const [wowRoot, setWowRoot] = useState(settings.wowRoot ?? "");
  const [server, setServer] = useState(settings.server);
  const [token, setToken] = useState("");
  const [useCode, setUseCode] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [notify, setNotify] = useState(notificationsOn);

  async function run<T>(what: string, action: () => Promise<T>, apply: (v: T) => void, doneText?: string) {
    setBusy(what);
    setProblem(null);
    setDone(null);
    try {
      apply(await action());
      if (doneText) setDone(doneText);
      return true;
    } catch (e) {
      setProblem(message(e));
      return false;
    } finally {
      setBusy(null);
    }
  }

  const save = (root: string, flavor: string, address: string) => run("save", () => api.saveSettings(root || null, flavor, address), onUpdate, "Saved.");
  const rootDirty = wowRoot !== (settings.wowRoot ?? "");
  const serverDirty = server.trim().replace(/\/+$/, "") !== settings.server;
  const flavors = wow.flavors.includes(settings.flavor) ? wow.flavors : [settings.flavor, ...wow.flavors];

  async function choose() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const picked = await open({ directory: true, title: "World of Warcraft folder", defaultPath: wowRoot || undefined });
    if (typeof picked === "string") {
      setWowRoot(picked);
      save(picked, settings.flavor, settings.server);
    }
  }

  return (
    <div className="settings">
      <div className="settings-body">
        {(problem || done) && <p className={`settings-status${problem ? " is-problem" : ""}`} role="status">{problem ?? done}</p>}

        <section className="set-section">
          <h2>Discord</h2>
          <p className="set-intro">Emberlight uses your Discord account to check that you are in the guild. It never sees your Discord or Battle.net password.</p>
          <div className="set-row">
            <div className="set-label">{signedIn ? "Signed in as" : "Not signed in"}</div>
            <div className="set-control">
              {signedIn ? (
                <>
                  <p className="set-text set-account">
                    <strong>{settings.memberName ?? "Guild member"}</strong>
                    {settings.discordId && <small>Discord ID {settings.discordId}</small>}
                  </p>
                  <button className="btn btn-small" disabled={!!busy} onClick={() => run("signout", api.signOut, onUpdate)}>
                    Sign out
                  </button>
                </>
              ) : busy === "discord" ? (
                <>
                  <p className="set-text">Finish signing in with Discord in your browser.</p>
                  <button className="btn btn-small" onClick={() => api.cancelSignIn()}>
                    Cancel
                  </button>
                </>
              ) : (
                <>
                  <p className="set-text">Use the Discord account you have in the Emberlight server. Guild members only.</p>
                  <button className="btn" disabled={!!busy || !settings.server} onClick={() => run("discord", api.signInDiscord, onUpdate)}>
                    Sign in with Discord
                  </button>
                </>
              )}
            </div>
          </div>
        </section>

        <section className="set-section">
          <h2>Game</h2>
          <p className="set-intro">Emberlight finds World of Warcraft by itself. Only change the folder if it picked the wrong one.</p>
          <div className="set-row">
            <div className="set-label">
              Game folder
              <small>{wow.root && !wow.problem ? "Found" : wow.problem ?? "Not found"}</small>
            </div>
            <div className="set-control">
              <input value={wowRoot} onChange={(e) => setWowRoot(e.target.value)} placeholder={wow.root ?? "Not found"} spellCheck={false} />
              {inTauri && (
                <button className="btn btn-small" disabled={!!busy} onClick={choose}>
                  Choose
                </button>
              )}
              {rootDirty && (
                <button className="btn btn-small" disabled={!!busy} onClick={() => save(wowRoot, settings.flavor, settings.server)}>
                  Save
                </button>
              )}
            </div>
          </div>
          <div className="set-row">
            <div className="set-label">Game version</div>
            <div className="set-control">
              <select value={settings.flavor} disabled={!!busy} onChange={(e) => save(wowRoot, e.target.value, settings.server)}>
                {flavors.map((f) => (
                  <option key={f} value={f}>
                    {flavorName(f)}
                  </option>
                ))}
              </select>
            </div>
          </div>
          <div className="set-row">
            <div className="set-label">
              Game accounts on this computer
              <small>Found in your game folder. Emberlight reads your characters and the addon's saved data from these.</small>
            </div>
            <div className="set-control">
              <p className="set-text">{wow.accounts.length ? wow.accounts.join(", ") : "None yet. Log in once with the addon enabled."}</p>
            </div>
          </div>
        </section>

        <section className="set-section">
          <h2>Emberlight addon</h2>
          <div className="set-row">
            <div className="set-label">
              Version
              <small>Checked when Emberlight Companion opens.</small>
            </div>
            <div className="set-control is-column">
              <p className="set-text">
                {addon.installed ? (
                  <>
                    Version <strong>{addon.installed}</strong> is installed.
                  </>
                ) : (
                  "Not installed in this game version."
                )}
              </p>
              {lastAddonCheck && <p className={`set-note${lastAddonCheck.error ? " is-problem" : ""}`}>{lastAddonCheck.message}</p>}
              <label className="set-check">
                <input
                  type="checkbox"
                  checked={settings.autoUpdateAddon}
                  disabled={!!busy}
                  onChange={(e) => run("auto", () => api.setAutoUpdateAddon(e.target.checked), onUpdate)}
                />
                <span>
                  Update the addon by itself
                  <small>When Emberlight Companion opens and the game is closed. When off, you are told a new version is ready and choose when to update.</small>
                </span>
              </label>
              {wow.root && !wow.problem && (
                <div className="set-actions">
                  <button className="btn btn-small" disabled={!!busy || wow.gameRunning} onClick={() => run("addon", api.updateAddon, onUpdate)}>
                    {busy === "addon" ? "Checking" : addon.installed ? "Check for updates" : "Install Emberlight"}
                  </button>
                  {addon.previous && (
                    <button className="btn btn-small" disabled={!!busy || wow.gameRunning} onClick={() => run("restore", api.restoreAddon, onUpdate)}>
                      {busy === "restore" ? "Restoring" : `Go back to ${addon.previous}`}
                    </button>
                  )}
                </div>
              )}
              {wow.gameRunning && (
                <p className="set-note">
                  Close World of Warcraft to change the addon.{wow.running.length > 0 && ` Still running: ${wow.running.join(", ")}.`}
                </p>
              )}
            </div>
          </div>
        </section>

        <section className="set-section">
          <h2>Emberlight Companion</h2>
          <div className="set-row">
            <div className="set-label">
              Version
              <small>Checked when it opens. Updating restarts it.</small>
            </div>
            <div className="set-control is-column">
              <p className="set-text">
                Version <strong>{overview.launcherVersion}</strong>
                {launcherUpdate ? (
                  <>
                    . Version <strong>{launcherUpdate.version}</strong> is ready.
                  </>
                ) : (
                  "."
                )}
              </p>
              {launcherUpdate?.notes && <p className="set-note">{launcherUpdate.notes}</p>}
              <label className="set-check">
                <input type="checkbox" checked={settings.keepInTray} disabled={!!busy} onChange={(e) => run("tray", () => api.setKeepInTray(e.target.checked), onUpdate)} />
                <span>
                  Keep running in the tray
                  <small>Closing the window keeps Emberlight Companion running beside the clock, for notifications and updates. Quit from its tray icon.</small>
                </span>
              </label>
              <label className="set-check">
                <input
                  type="checkbox"
                  checked={notify}
                  onChange={(e) => {
                    setNotificationsOn(e.target.checked);
                    setNotify(e.target.checked);
                  }}
                />
                <span>
                  Windows notifications
                  <small>A new guild event, and an event you said you will join an hour before it starts. Only while Emberlight Companion is running.</small>
                </span>
              </label>
              <div className="set-actions">
                {launcherUpdate ? (
                  <button className="btn btn-small" disabled={!!busy || overview.watching} onClick={() => run("launcher", () => api.installLauncherUpdate(), () => undefined)}>
                    {busy === "launcher" ? "Updating" : "Restart to update"}
                  </button>
                ) : (
                  <button
                    className="btn btn-small"
                    disabled={!!busy}
                    onClick={() =>
                      run("launcher-check", api.launcherUpdate, (u) => {
                        onLauncherUpdate(u);
                        if (!u) setDone("This is the newest version of Emberlight Companion.");
                      })
                    }
                  >
                    {busy === "launcher-check" ? "Checking" : "Check for updates"}
                  </button>
                )}
              </div>
            </div>
          </div>
        </section>

        {/* The guild owns its server address (emberlightrp.com), so members never change it: the server
            address and the sign-in code for a development server are only offered in development builds. */}
        {import.meta.env.DEV && (
          <section className="set-section">
            <h2>Development</h2>
            <p className="quiet">Only in development builds. Nothing here needs changing for normal use.</p>
            <div className="set-row">
              <div className="set-label">
                Server address
                <small>The guild's server.</small>
              </div>
              <div className="set-control">
                <input value={server} onChange={(e) => setServer(e.target.value)} placeholder={DEFAULT_SERVER} spellCheck={false} />
                {serverDirty && (
                  <button className="btn btn-small" disabled={!!busy} onClick={() => save(wowRoot, settings.flavor, server)}>
                    Save
                  </button>
                )}
                {!serverDirty && settings.server !== DEFAULT_SERVER && (
                  <button
                    className="btn btn-small"
                    disabled={!!busy}
                    onClick={() => {
                      setServer(DEFAULT_SERVER);
                      save(wowRoot, settings.flavor, DEFAULT_SERVER);
                    }}
                  >
                    Use default
                  </button>
                )}
              </div>
            </div>
            {!signedIn && (
              <div className="set-row">
                <div className="set-label">
                  Sign-in code
                  <small>For testing on a development server.</small>
                </div>
                <div className="set-control">
                  {useCode ? (
                    <>
                      <input type="password" value={token} onChange={(e) => setToken(e.target.value)} autoComplete="off" spellCheck={false} aria-label="Sign-in code" />
                      <button
                        className="btn btn-small"
                        disabled={!!busy || !token.trim()}
                        onClick={async () => {
                          if (await run("signin", () => api.signIn(token), onUpdate, "Signed in.")) setToken("");
                        }}
                      >
                        {busy === "signin" ? "Checking" : "Sign in"}
                      </button>
                    </>
                  ) : (
                    <button className="link" onClick={() => setUseCode(true)}>
                      Use a sign-in code
                    </button>
                  )}
                </div>
              </div>
            )}
          </section>
        )}
      </div>
    </div>
  );
}
