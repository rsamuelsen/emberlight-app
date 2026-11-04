import { openInBrowser, WEBSITE, type CharactersView, type Claim } from "./api";
import { Mark } from "./StatusCard";
import { Arrow, EmptyState } from "./UI";

export const STATUS: Record<Claim["status"], string> = {
  verified: "Verified",
  pending: "Waiting for an officer",
  refused: "Not approved",
};

export const linkOnWebsite = () => openInBrowser(`${WEBSITE}/portal/characters`);

/** The register stays read only; all linking and management happen on the website. */
export function Characters({ characters, signedIn, problem, onRetry }: { characters: CharactersView | null; signedIn: boolean; problem: string | null; onRetry: () => void }) {
  return (
    <div className="characters-page">
      <div className="character-intro">
        <p>Link the characters you play on the guild website. An officer checks each request.</p>
        {signedIn && <button className="btn btn-primary" onClick={linkOnWebsite}>Link a character <Arrow /></button>}
      </div>
      {signedIn && problem && <div className="settings-status is-problem" role="alert"><p>Could not refresh your characters. {problem}</p><button className="link" onClick={onRetry}>Try again</button></div>}
      {!signedIn ? <EmptyState title="Sign in to see your characters." detail="Use Sign in with Discord in the title bar or Settings." /> : !characters ? !problem && <EmptyState title="Reading the register…" /> : (
        <div className="character-grid">
          <section className="character-panel">
            <header className="section-head"><h2>Linked characters</h2><span className="tab-count">{characters.mine.length}</span></header>
            {characters.mine.length === 0 ? <EmptyState title="No characters linked yet." detail="Link a character on the website to request verification." /> : (
              <ul className="roll character-roll">{characters.mine.map((c) => (
                <li key={c.id} className={`roll-row is-${c.status}`}>
                  <span className="character-emblem"><Mark status={c.status} /></span>
                  <span className="roll-name">{c.name}</span>
                  <span className="roll-status">{STATUS[c.status]}</span>
                  {c.status === "refused" && <div className="character-reason">{c.reason && <p>{c.reason}</p>}<button className="link" onClick={linkOnWebsite}>Fix this on the website <Arrow external /></button></div>}
                </li>
              ))}</ul>
            )}
            <p className="character-note">Once verified, the events and notices you post with this character in game can reach the guild through the Companion.</p>
          </section>
          <section className="character-panel detected-panel">
            <header className="section-head"><h2>On this computer</h2></header>
            <p className="set-intro">Characters played here that are not linked yet.</p>
            {characters.found.length ? <ul className="detected-list">{characters.found.map((f) => <li key={`${f.name}-${f.realm}`}><span>{f.name}</span>{characters.realms.length > 1 && <small>{f.realm}</small>}<button className="btn btn-small" onClick={linkOnWebsite} aria-label={`Link ${f.name}`}>Link <Arrow external /></button></li>)}</ul> : <EmptyState title="No unlinked characters found." />}
            <p className="set-note">Manage your characters on the guild website. This list refreshes when you return.</p>
          </section>
        </div>
      )}
    </div>
  );
}
