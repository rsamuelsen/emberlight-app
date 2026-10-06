import { CATEGORIES, type Notice } from "./api";
import { adventureWhen, countdown, daysUntil, displayName, fmtDayMonth, fmtMonth, fmtTime, fmtWeekdayLong } from "./events";

/** The Events page shows the guild's official events or members' adventures. */
export type EventsView = "guild" | "adventures";

interface Props {
  view: EventsView;
  onView: (v: EventsView) => void;
  events: Notice[];
  now: number;
  signedIn: boolean;
  onRead: (n: Notice) => void;
}

function dayLabel(start: number, now: number) {
  const days = daysUntil(start, now);
  if (days <= 0) return "Today";
  if (days === 1) return "Tomorrow";
  return fmtWeekdayLong.format(start * 1000);
}

function Row({ n, now, onRead }: { n: Notice; now: number; onRead: () => void }) {
  const adventure = n.category !== 4;
  return (
    <button className={`agenda-row${n.cancelled ? " is-withdrawn" : ""}`} onClick={onRead}>
      <span className="agenda-time">{fmtTime.format(n.start * 1000)}</span>
      <span className="agenda-main">
        {adventure && <span className="agenda-kind">{CATEGORIES[n.category]}</span>}
        <span className="agenda-title">{n.title}</span>
        {n.location && <span className="agenda-where">{n.location}</span>}
        <span className="agenda-body">{n.body}</span>
      </span>
      <span className="agenda-side">
        <span className={`agenda-count${adventure && n.start <= now ? " is-now" : ""}`}>
          {n.cancelled ? "Withdrawn" : adventure ? adventureWhen(n, now) : countdown(n.start, now)}
        </span>
        <span className="agenda-author">{displayName(n.author)}</span>
      </span>
    </button>
  );
}

function Switch({ view, onView }: { view: EventsView; onView: (v: EventsView) => void }) {
  return (
    <div className="agenda-switch" role="tablist" aria-label="Which events">
      {(
        [
          ["guild", "Guild events"],
          ["adventures", "Adventures"],
        ] as const
      ).map(([id, name]) => (
        <button key={id} role="tab" aria-selected={view === id} className={view === id ? "is-current" : ""} onClick={() => onView(id)}>
          {name}
        </button>
      ))}
    </div>
  );
}

/** Official guild events or members' adventures, grouped by day. */
export function Agenda({ view, onView, events, now, signedIn, onRead }: Props) {
  const planned = events.filter((n) => !n.cancelled);
  const withdrawn = events.filter((n) => n.cancelled);

  if (events.length === 0) {
    return (
      <div className="agenda-page">
        <Switch view={view} onView={onView} />
        <div className="page-empty">
          <p>{view === "guild" ? "No guild events planned." : "No adventures posted here yet."}</p>
          <p className="page-empty-hint">
            {!signedIn
              ? "Sign in under Settings to fetch the guild's events."
              : view === "guild"
                ? "Officers post events on the website or in game; they appear here."
                : "Members post adventures in game, on the Emberlight board. Ones posted by members who use Emberlight Companion show here too."}
          </p>
        </div>
      </div>
    );
  }

  const days: { key: string; start: number; items: Notice[] }[] = [];
  for (const n of planned) {
    // An adventure under way is listed under today, not the day it began.
    const at = Math.max(n.start, view === "adventures" ? now : n.start);
    const d = new Date(at * 1000);
    const key = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
    const last = days[days.length - 1];
    if (last?.key === key) last.items.push(n);
    else days.push({ key, start: at, items: [n] });
  }

  return (
    <div className="agenda-page">
      <Switch view={view} onView={onView} />
      <div className="agenda">
        {days.map((day) => (
          <section key={day.key} className="agenda-day">
            <header className="agenda-date">
              <strong>{new Date(day.start * 1000).getDate()}</strong>
              <span>{fmtMonth.format(day.start * 1000)}</span>
            </header>
            <div className="agenda-items">
              <h3>
                {dayLabel(day.start, now)}
                <small>{fmtDayMonth.format(day.start * 1000)}</small>
              </h3>
              {day.items.map((n) => (
                <Row key={`${n.scope}/${n.id}`} n={n} now={now} onRead={() => onRead(n)} />
              ))}
            </div>
          </section>
        ))}
        {withdrawn.length > 0 && (
          <section className="agenda-day is-past">
            <header className="agenda-date" />
            <div className="agenda-items">
              <h3>Withdrawn</h3>
              {withdrawn.map((n) => (
                <Row key={`${n.scope}/${n.id}`} n={n} now={now} onRead={() => onRead(n)} />
              ))}
            </div>
          </section>
        )}
      </div>
    </div>
  );
}
