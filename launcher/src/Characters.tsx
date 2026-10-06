import { openInBrowser, WEBSITE, type CharactersView, type Claim } from "./api";
import { Mark } from "./StatusCard";

export const STATUS: Record<Claim["status"], string> = {
  verified: "Verified",
  pending: "Waiting for an officer",
  refused: "Not approved",
};

/** Characters are linked on the website, which explains the whole process; this page shows them. */
export const linkOnWebsite = () => openInBrowser(`${WEBSITE}/portal/characters`);

/** Linked characters and their state, read only, with the way to the website to link one. */
export function Characters({ characters, signedIn }: { characters: CharactersView | null; signedIn: boolean }) {
  return (
    <div className="settings">
      <div className="settings-body">
        <section className="set-section">
          <h2>Your characters</h2>
          <p className="set-intro">
            Link each character you play on the guild website. An officer checks the request. Once a character is verified, events and notices you post
            with it in game reach the guild through Emberlight, even while you are offline.
          </p>
          {!signedIn ? (
            <p className="set-text">Sign in under Settings first.</p>
          ) : !characters ? (
            <p className="set-text">Reading the register...</p>
          ) : (
            <>
              <div className="set-row">
                <div className="set-label">Linked</div>
                <div className="set-control is-column">
                  {characters.mine.length === 0 ? (
                    <p className="set-text">None linked yet.</p>
                  ) : (
                    <ul className="roll">
                      {characters.mine.map((c) => (
                        <li key={c.id} className={`roll-row is-${c.status}`}>
                          <Mark status={c.status} />
                          <span className="roll-name">{c.name}</span>
                          <span className="roll-status">{STATUS[c.status]}</span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </div>

              {characters.found.length > 0 && (
                <div className="set-row">
                  <div className="set-label">
                    Seen on this computer
                    <small>Played here, not linked yet.</small>
                  </div>
                  <div className="set-control is-wrap">
                    {characters.found.map((f) => (
                      <span key={`${f.name}-${f.realm}`} className="chip is-plain">
                        {f.name}
                        {characters.realms.length > 1 && <small>{f.realm}</small>}
                      </span>
                    ))}
                  </div>
                </div>
              )}

              <div className="set-row">
                <div className="set-label">
                  Link a character
                  <small>Opens the guild website in your browser. This list updates when you come back.</small>
                </div>
                <div className="set-control">
                  <button className="btn" onClick={linkOnWebsite}>
                    Link a character on the website
                  </button>
                </div>
              </div>
            </>
          )}
        </section>
      </div>
    </div>
  );
}
