import type { ReactNode } from "react";
import { CATEGORIES, type Announcement, type Notice } from "./api";
import type { EventsView } from "./Agenda";
import { NewsList } from "./Announcements";
import { fmtDateNumber, serverWhen, isGoing, adventureWhen, countdown, displayName, fmtMonth, fmtWeekday, Seal } from "./events";
import { Arrow, EmptyState } from "./UI";

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
  isUnread?: (a: Announcement) => boolean;
}

function ListRow({ n, meta, onRead }: { n: Notice; meta: ReactNode; onRead: () => void }) {
  return (
    <li>
      <button className="upcoming-row" onClick={onRead}>
        <span className="date-block">
          <span>{fmtWeekday.format(n.start * 1000)}</span>
          <strong>{fmtDateNumber.format(n.start * 1000)}</strong>
          <span>{fmtMonth.format(n.start * 1000)}</span>
        </span>
        <span className="upcoming-text">
          <span className="upcoming-title">{n.title}</span>{isGoing(n) && <span className="going-mark">You’re going</span>}
          <span className="upcoming-meta">{meta}</span>
        </span>
        <Arrow />
      </button>
    </li>
  );
}

function Featured({ n, now, onRead }: { n: Notice; now: number; onRead: () => void }) {
  return (
    <button className="featured" onClick={onRead}>
      <span className="featured-date" aria-hidden="true">
        <span>{fmtMonth.format(n.start * 1000)}</span>
        <strong>{fmtDateNumber.format(n.start * 1000)}</strong>
        <span>{fmtWeekday.format(n.start * 1000)}</span>
      </span>
      <span className="featured-content">
        <span className="featured-label">Next guild event</span>
        <span className="featured-title">{n.title}</span>{isGoing(n) && <span className="going-mark">You’re going</span>}
        <span className="featured-when">{serverWhen(n.start, true)}</span>
        {n.location && <span className="featured-location">{n.location}</span>}
        <span className="featured-body">{n.body}</span>
        <span className="featured-foot">
          <span className="featured-count">{countdown(n.start, now)}</span>
          <span className="featured-author">Hosted by {displayName(n.author)}</span>
          <span className="featured-open">View event <Arrow /></span>
        </span>
      </span>
      <Seal />
    </button>
  );
}

export function Home({ events, adventures, now, signedIn, announcements, newsProblem, onRead, onNews, onEvents, isUnread }: Props) {
  const upcoming = events.filter((n) => !n.cancelled);
  const [next, ...later] = upcoming;

  return (
    <div className="home">
      {next ? <Featured n={next} now={now} onRead={() => onRead(next)} /> : (
        <section className="featured-empty">
          <span className="empty-calendar" aria-hidden="true"><svg viewBox="0 0 20 20"><path d="M4 4h12v13H4zM4 8h12M7 2v4M13 2v4M7 11h2M11 11h2" /></svg></span>
          <div><span className="eyebrow">Next guild event</span><p>No guild events planned.</p></div>
          {signedIn && <button className="link" onClick={() => onEvents("guild")}>View events <Arrow /></button>}
        </section>
      )}
      {upcoming.some(isGoing) && <section className="home-col joining-events"><header className="section-head"><h2>Events you’re joining</h2></header>
        <ol className="upcoming">{upcoming.filter(isGoing).slice(0, 3).map(n => <ListRow key={n.scope + "/" + n.id} n={n} onRead={() => onRead(n)} meta={serverWhen(n.start, true)} />)}</ol>
      </section>}
      <div className="home-grid">
        <section className="home-col" aria-label="Latest announcements">
          <header className="section-head"><h2>Announcements</h2>{!!announcements?.length && <button className="link" onClick={() => onNews(null)}>View all <Arrow /></button>}</header>
          <NewsList items={announcements} signedIn={signedIn} problem={newsProblem} limit={4} onOpen={onNews} isUnread={isUnread} />
        </section>
        <div className="home-stack">
          <section className="home-col" aria-label="Later events">
            <header className="section-head"><h2>Later events</h2>{upcoming.length > 0 && <button className="link" onClick={() => onEvents("guild")}>View all <Arrow /></button>}</header>
            {later.length === 0 ? <EmptyState title={next ? "Nothing else planned yet." : "Nothing planned yet."} /> : (
              <ol className="upcoming">{later.slice(0, 3).map((n) => <ListRow key={`${n.scope}/${n.id}`} n={n} onRead={() => onRead(n)} meta={<>{serverWhen(n.start)}{n.location && <> · {n.location}</>}</>} />)}</ol>
            )}
          </section>
          <section className="home-col" aria-label="Adventures">
            <header className="section-head"><h2>Adventures</h2>{adventures.length > 0 && <button className="link" onClick={() => onEvents("adventures")}>View all <Arrow /></button>}</header>
            {adventures.length === 0 ? <EmptyState title={signedIn ? "No adventures posted here yet." : "Sign in to see members’ adventures."} /> : (
              <ol className="upcoming">{adventures.slice(0, 3).map((n) => <ListRow key={`${n.scope}/${n.id}`} n={n} onRead={() => onRead(n)} meta={<>{CATEGORIES[n.category]} · {n.start <= now ? <em className="is-now">{adventureWhen(n, now)}</em> : serverWhen(n.start)} · {displayName(n.author)}</>} />)}</ol>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
