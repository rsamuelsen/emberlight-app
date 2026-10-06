import type { ReactNode } from "react";
import { CATEGORIES, type Announcement, type Notice } from "./api";
import type { EventsView } from "./Agenda";
import { NewsList } from "./Announcements";
import { adventureWhen, countdown, displayName, fmtLong, fmtTime, fmtWeekday, Seal } from "./events";

interface Props {
  events: Notice[];
  adventures: Notice[];
  now: number;
  signedIn: boolean;
  announcements: Announcement[] | null;
  newsProblem: string | null;
  onRead: (n: Notice) => void;
  onNews: (id: string | null) => void;
  onEvents: (view: EventsView) => void;
}

/** One line of a short list: the day, the title, and the time and place or the adventure's kind. */
function ListRow({ n, meta, onRead }: { n: Notice; meta: ReactNode; onRead: () => void }) {
  return (
    <li>
      <button className="upcoming-row" onClick={onRead}>
        <span className="date-block">
          <span>{fmtWeekday.format(n.start * 1000)}</span>
          <strong>{new Date(n.start * 1000).getDate()}</strong>
        </span>
        <span className="upcoming-text">
          <span className="upcoming-title">{n.title}</span>
          <span className="upcoming-meta">{meta}</span>
        </span>
      </button>
    </li>
  );
}

function Featured({ n, now, onRead }: { n: Notice; now: number; onRead: () => void }) {
  return (
    <button className="featured" onClick={onRead}>
      <Seal />
      <span className="featured-label">Next guild event</span>
      <span className="featured-title">{n.title}</span>
      <span className="featured-when">
        {fmtLong.format(n.start * 1000)}
        {n.location && <> · {n.location}</>}
      </span>
      <span className="featured-body">{n.body}</span>
      <span className="featured-foot">
        <span className="featured-count">{countdown(n.start, now)}</span>
        <span className="featured-author">{displayName(n.author)}</span>
      </span>
    </button>
  );
}

export function Home({ events, adventures, now, signedIn, announcements, newsProblem, onRead, onNews, onEvents }: Props) {
  const upcoming = events.filter((n) => !n.cancelled);
  const [next, ...later] = upcoming;

  return (
    <div className="home">
      {next ? (
        <Featured n={next} now={now} onRead={() => onRead(next)} />
      ) : (
        <div className="featured is-empty">
          <span className="featured-label">Next guild event</span>
          <span className="featured-none">No guild events planned.</span>
          {!signedIn && <span className="featured-hint">Sign in under Settings to fetch the guild's events.</span>}
        </div>
      )}

      <div className="home-grid">
        <section className="home-col" aria-label="Latest announcements">
          <header className="section-head">
            <h2>Announcements</h2>
            {announcements && announcements.length > 0 && (
              <button className="link" onClick={() => onNews(null)}>
                All
              </button>
            )}
          </header>
          <NewsList items={announcements} signedIn={signedIn} problem={newsProblem} limit={4} onOpen={(id) => onNews(id)} />
        </section>

        <div className="home-stack">
          <section className="home-col" aria-label="Later events">
            <header className="section-head">
              <h2>Later events</h2>
              {upcoming.length > 0 && (
                <button className="link" onClick={() => onEvents("guild")}>
                  All events
                </button>
              )}
            </header>
            {later.length === 0 ? (
              <p className="quiet">{next ? "Nothing else planned yet." : "Nothing planned yet."}</p>
            ) : (
              <ol className="upcoming">
                {later.slice(0, 3).map((n) => (
                  <ListRow
                    key={`${n.scope}/${n.id}`}
                    n={n}
                    onRead={() => onRead(n)}
                    meta={
                      <>
                        {fmtTime.format(n.start * 1000)}
                        {n.location && <> · {n.location}</>}
                      </>
                    }
                  />
                ))}
              </ol>
            )}
          </section>

          <section className="home-col" aria-label="Adventures">
            <header className="section-head">
              <h2>Adventures</h2>
              {adventures.length > 0 && (
                <button className="link" onClick={() => onEvents("adventures")}>
                  All adventures
                </button>
              )}
            </header>
            {adventures.length === 0 ? (
              <p className="quiet">{signedIn ? "No adventures posted here yet." : "Sign in to see members' adventures."}</p>
            ) : (
              <ol className="upcoming">
                {adventures.slice(0, 3).map((n) => (
                  <ListRow
                    key={`${n.scope}/${n.id}`}
                    n={n}
                    onRead={() => onRead(n)}
                    meta={
                      <>
                        {CATEGORIES[n.category]} · {n.start <= now ? <em className="is-now">{adventureWhen(n, now)}</em> : fmtTime.format(n.start * 1000)} ·{" "}
                        {displayName(n.author)}
                      </>
                    }
                  />
                ))}
              </ol>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
