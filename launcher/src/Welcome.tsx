import { useState } from "react";
import { api, FLAVOR_NAMES, inTauri, type CharactersView, type Overview } from "./api";
import { linkOnWebsite, STATUS } from "./Characters";
import { Scene } from "./Scene";
import { Mark } from "./StatusCard";

const message = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : "Something went wrong.");

/** Remembered in this app's own storage once the guide has been finished or left. */
const DONE_KEY = "emberlight.setup-done";
export const setupDone = () => {
  try {
    return localStorage.getItem(DONE_KEY) === "1";
  } catch {
    return false;
  }
};
const rememberDone = () => {
  try {
    localStorage.setItem(DONE_KEY, "1");
  } catch {
    // Without storage the guide simply shows again while something is missing.
  }
};

/** What the guide sets up, and whether each part is in place. */
export function setupState(overview: Overview, characters: CharactersView | null) {
  const folder = !!overview.wow.root && !overview.wow.problem;
  return {
    folder,
    addon: folder && !!overview.addon.installed,
    account: overview.signedIn,
    character: overview.signedIn && !!characters?.mine.some((c) => c.status !== "refused"),
  };
}

type Step = "welcome" | "folder" | "addon" | "account" | "character" | "ready";
const STEPS: [Exclude<Step, "welcome" | "ready">, string][] = [
  ["folder", "Game folder"],
  ["addon", "Emberlight addon"],
  ["account", "Discord account"],
  ["character", "Your character"],
];
const ORDER: Step[] = ["welcome", ...STEPS.map(([id]) => id), "ready"];

interface Props {
  overview: Overview;
  onUpdate: (o: Overview) => void;
  characters: CharactersView | null;
  onDone: () => void;
}

/** The first-run guide: fills the window until the member finishes or leaves it. */
export function Welcome({ overview, onUpdate, characters, onDone }: Props) {
  const { wow, addon, signedIn, settings } = overview;
  const [step, setStep] = useState<Step>("welcome");
  const [busy, setBusy] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  const state = setupState(overview, characters);
  const index = ORDER.indexOf(step);
  const go = (to: Step) => {
    setProblem(null);
    setStep(to);
  };
  const finish = () => {
    rememberDone();
    onDone();
  };

  async function run<T>(what: string, action: () => Promise<T>, apply: (value: T) => void) {
    setBusy(what);
    setProblem(null);
    try {
      apply(await action());
    } catch (e) {
      setProblem(message(e));
    } finally {
      setBusy(null);
    }
  }

  async function chooseFolder() {
    let picked: string | null = null;
    if (inTauri) {
      const { open } = await import("@tauri-apps/plugin-dialog");
      const answer = await open({ directory: true, title: "World of Warcraft folder" });
      picked = typeof answer === "string" ? answer : null;
    } else if (import.meta.env.DEV) {
      picked = "C:\\Program Files (x86)\\World of Warcraft";
    }
    if (picked) run("folder", () => api.saveSettings(picked, settings.flavor, settings.server), onUpdate);
  }

  const complete = step === "welcome" || step === "ready" || state[step];

  return (
    <>
      <aside className="side">
        <Scene road={state.account ? "idle" : "dark"} />
        <ol className="card guide-steps" aria-label="Setup steps">
          {STEPS.map(([id, name]) => (
            <li key={id}>
              <button className={`guide-step${step === id ? " is-current" : ""}`} aria-current={step === id ? "step" : undefined} onClick={() => go(id)}>
                <Mark status={state[id] ? "verified" : "pending"} />
                <span>{name}</span>
                <small>{state[id] ? "Done" : step === id ? "Now" : ""}</small>
              </button>
            </li>
          ))}
        </ol>
      </aside>

      <main className="hall guide">
        <div className="guide-page" key={step}>
          {step !== "welcome" && step !== "ready" && <p className="guide-count">Step {index} of {STEPS.length}</p>}

          {step === "welcome" && (
            <>
              <h1>Welcome to Emberlight</h1>
              <p className="guide-lead">
                Emberlight Companion sits beside the game. It installs the Emberlight addon and keeps it up to date, shows what the guild has planned,
                and starts World of Warcraft through Battle.net.
              </p>
              <p className="guide-text">
                It does not play the game for you or automate anything in it, and it never sees your Discord or Battle.net password.
              </p>
              <p className="guide-text">Four short steps and you are ready. Each one can be skipped and finished later.</p>
            </>
          )}

          {step === "folder" && (
            <>
              <h1>Game folder</h1>
              <p className="guide-lead">Where World of Warcraft is installed on this computer.</p>
              <div className="guide-box">
                <Mark status={state.folder ? "verified" : "pending"} />
                <div>
                  <p className="guide-value">{wow.root ?? "Not found yet"}</p>
                  <p className="set-note">
                    {state.folder ? "Found. If this is not the right folder, choose another." : wow.problem ?? "Emberlight looked in the usual places and did not find it."}
                  </p>
                </div>
                <button className={state.folder ? "btn btn-small" : "btn"} disabled={!!busy} onClick={chooseFolder}>
                  {busy === "folder" ? "Saving" : state.folder ? "Change" : "Choose folder"}
                </button>
              </div>
              {wow.flavors.length > 1 && (
                <div className="guide-field">
                  <label htmlFor="guide-flavor">Game version</label>
                  <select
                    id="guide-flavor"
                    value={settings.flavor}
                    disabled={!!busy}
                    onChange={(e) => run("folder", () => api.saveSettings(settings.wowRoot, e.target.value, settings.server), onUpdate)}
                  >
                    {wow.flavors.map((f) => (
                      <option key={f} value={f}>
                        {FLAVOR_NAMES[f] ?? f}
                      </option>
                    ))}
                  </select>
                </div>
              )}
            </>
          )}

          {step === "addon" && (
            <>
              <h1>Emberlight addon</h1>
              <p className="guide-lead">The guild's noticeboard and letters inside the game. The Companion installs it and keeps it up to date.</p>
              <div className="guide-box">
                <Mark status={state.addon ? "verified" : "pending"} />
                <div>
                  <p className="guide-value">{state.addon ? `Version ${addon.installed} is installed` : "Not installed yet"}</p>
                  <p className="set-note">
                    {!state.folder
                      ? "Choose your game folder first."
                      : wow.gameRunning && !state.addon
                        ? `Close World of Warcraft first.${wow.running.length > 0 ? ` Still running: ${wow.running.join(", ")}.` : ""}`
                        : state.addon
                          ? "You will see it in game the next time you log in."
                          : "It goes straight into the game's AddOns folder. Nothing else is changed."}
                  </p>
                </div>
                {!state.folder ? (
                  <button className="btn btn-small" onClick={() => go("folder")}>
                    Game folder
                  </button>
                ) : (
                  !state.addon && (
                    <button className="btn" disabled={!!busy || wow.gameRunning} onClick={() => run("addon", api.updateAddon, onUpdate)}>
                      {busy === "addon" ? "Installing" : "Install"}
                    </button>
                  )
                )}
              </div>
            </>
          )}

          {step === "account" && (
            <>
              <h1>Discord account</h1>
              <p className="guide-lead">Emberlight uses your Discord account to check that you are in the guild.</p>
              <div className="guide-box">
                <Mark status={signedIn ? "verified" : "pending"} />
                <div>
                  <p className="guide-value">{signedIn ? `Signed in as ${settings.memberName ?? "a guild member"}` : "Not signed in"}</p>
                  <p className="set-note">
                    {signedIn
                      ? "The guild's events and announcements are now shown here."
                      : busy === "discord"
                        ? "Finish signing in with Discord in your browser, then come back here."
                        : "Your browser opens Discord's own page. Use the account you have in the Emberlight server."}
                  </p>
                </div>
                {!signedIn &&
                  (busy === "discord" ? (
                    <button className="btn btn-small" onClick={() => api.cancelSignIn()}>
                      Cancel
                    </button>
                  ) : (
                    <button className="btn" disabled={!!busy} onClick={() => run("discord", api.signInDiscord, onUpdate)}>
                      Sign in
                    </button>
                  ))}
              </div>
            </>
          )}

          {step === "character" && (
            <>
              <h1>Your character</h1>
              <p className="guide-lead">
                Link the character you play on the guild website. An officer checks the request, and after that what you post with it in game reaches
                the guild, even while you are offline.
              </p>
              {!signedIn ? (
                <div className="guide-box">
                  <Mark status="pending" />
                  <div>
                    <p className="guide-value">Sign in first</p>
                    <p className="set-note">A character is linked to your Discord account.</p>
                  </div>
                  <button className="btn btn-small" onClick={() => go("account")}>
                    Discord account
                  </button>
                </div>
              ) : !characters ? (
                <p className="guide-text">Reading the register...</p>
              ) : (
                <>
                  {characters.mine.length > 0 && (
                    <ul className="roll guide-roll">
                      {characters.mine.map((c) => (
                        <li key={c.id} className={`roll-row is-${c.status}`}>
                          <Mark status={c.status} />
                          <span className="roll-name">{c.name}</span>
                          <span className="roll-status">{STATUS[c.status]}</span>
                        </li>
                      ))}
                    </ul>
                  )}
                  {characters.found.length > 0 && (
                    <div className="guide-field">
                      <label>Seen on this computer, not linked yet</label>
                      <div className="guide-chips">
                        {characters.found.map((f) => (
                          <span key={`${f.name}-${f.realm}`} className="chip is-plain">
                            {f.name}
                            {characters.realms.length > 1 && <small>{f.realm}</small>}
                          </span>
                        ))}
                      </div>
                    </div>
                  )}
                  <div className="guide-field">
                    <button className={state.character ? "btn btn-small" : "btn"} onClick={linkOnWebsite}>
                      Link a character on the website
                    </button>
                  </div>
                  <p className="set-note">
                    {state.character
                      ? "You do not need to wait for the officer. More characters can be linked the same way."
                      : "The website opens in your browser and explains each step. Come back here afterwards: this step ticks itself."}
                  </p>
                </>
              )}
            </>
          )}

          {step === "ready" && (
            <>
              <h1>{STEPS.every(([id]) => state[id]) ? "You are ready" : "Almost ready"}</h1>
              <p className="guide-lead">
                {STEPS.every(([id]) => state[id])
                  ? "Press Play whenever you like. The Companion keeps the addon up to date and syncs when the game closes."
                  : "What is left can be finished at any time, under Settings and Characters."}
              </p>
              <ul className="roll guide-roll">
                {STEPS.map(([id, name]) => (
                  <li key={id} className="roll-row">
                    <Mark status={state[id] ? "verified" : "pending"} />
                    <span className="roll-name">{name}</span>
                    <span className="roll-status">{state[id] ? "Done" : "Not done"}</span>
                    {!state[id] && (
                      <button className="link" onClick={() => go(id)}>
                        Do it now
                      </button>
                    )}
                  </li>
                ))}
              </ul>
            </>
          )}

          {problem && (
            <p className="settings-status is-problem" role="status">
              {problem}
            </p>
          )}
        </div>

        <footer className="guide-foot">
          {index > 0 ? (
            <button className="link" disabled={busy === "discord"} onClick={() => go(ORDER[index - 1])}>
              Back
            </button>
          ) : (
            <button className="link" onClick={finish}>
              Set up later
            </button>
          )}
          <span className="guide-space" />
          {step === "ready" ? (
            <button className="btn" onClick={finish}>
              Open Emberlight
            </button>
          ) : complete ? (
            <button className="btn" onClick={() => go(ORDER[index + 1])}>
              {step === "welcome" ? "Begin" : "Continue"}
            </button>
          ) : (
            <button className="link" disabled={busy === "discord"} onClick={() => go(ORDER[index + 1])}>
              Skip for now
            </button>
          )}
        </footer>
      </main>
    </>
  );
}
