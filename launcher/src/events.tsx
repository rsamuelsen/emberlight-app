import { useEffect, useState } from "react";
import { openInBrowser, WEBSITE, type Notice } from "./api";

export const SERVER_TIME_ZONE = "Europe/Paris";
// Match the guild website: dates, grouping and countdowns all use the realm clock.
export const fmtWhen = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
export const fmtLong = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
export const fmtTime = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, hour: "2-digit", minute: "2-digit" });
export const fmtWeekday = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, weekday: "short" });
export const fmtWeekdayLong = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, weekday: "long" });
export const fmtMonth = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, month: "short" });
export const fmtDayMonth = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, day: "numeric", month: "long" });

export const fmtDateNumber = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, day: "numeric" });
const calendar = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const localCalendar = new Intl.DateTimeFormat("en-GB", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const localTime = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const localLong = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const parts = (formatter: Intl.DateTimeFormat, at: number) => Object.fromEntries(formatter.formatToParts(at * 1000).filter(p => p.type !== "literal").map(p => [p.type, p.value]));
export const serverDayKey = (at: number) => { const p = parts(calendar, at); return [p.year, p.month, p.day].join("-"); };
export function serverWhen(at: number, full = false) {
  const server = parts(calendar, at), local = parts(localCalendar, at);
  const differs = ["year", "month", "day", "hour", "minute"].some(k => server[k] !== local[k]);
  const otherDay = ["year", "month", "day"].some(k => server[k] !== local[k]);
  return (full ? fmtLong : fmtTime).format(at * 1000) + " server time" + (differs ? " (" + (otherDay ? localLong : localTime).format(at * 1000) + " your time)" : "");
}
export const isGoing = (n: Notice) => !!n.ownReplies?.some(r => r.response === "I will join");

export const displayName = (author: string) => author.split("-")[0];

/** The officers' official events, soonest first; withdrawn ones last. Member notices (the RP
 *  board) stay in game, where people can answer them. */
export function officialEvents(notices: Notice[]) {
  return notices
    .filter((n) => n.category === 4)
    .sort((a, b) => Number(a.cancelled) - Number(b.cancelled) || a.start - b.start || a.id.localeCompare(b.id));
}

/** Members' adventures (Journey, Call for aid, Gathering) that have not ended, soonest first. */
export function adventures(notices: Notice[], now: number) {
  return notices
    .filter((n) => n.category >= 1 && n.category <= 3 && !n.cancelled && n.expires > now)
    .sort((a, b) => a.start - b.start || a.id.localeCompare(b.id));
}

/** "Happening now" once an adventure has started, otherwise the countdown. */
export const adventureWhen = (n: Notice, now: number) => (n.start <= now ? "Happening now" : countdown(n.start, now));

/** Current time in seconds, updated every minute so countdowns stay right. */
export function useNow() {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    let timer: number;
    const tick = () => { setNow(Math.floor(Date.now() / 1000)); timer = window.setTimeout(tick, 60_000 - Date.now() % 60_000 + 20); };
    timer = window.setTimeout(tick, 60_000 - Date.now() % 60_000 + 20);
    return () => window.clearTimeout(timer);
  }, []);
  return now;
}

/** Compare realm calendar dates, including Paris daylight-saving changes. */
export const daysUntil = (start: number, now: number) => {
  const day = (at: number) => { const p = parts(calendar, at); return Date.UTC(+p.year, +p.month - 1, +p.day) / 86400000; };
  return day(start) - day(now);
};

/** "Under way", "In 40 minutes", "Tonight at 20:30", "Tomorrow at 19:00", "In 3 days". */
export function countdown(start: number, now: number) {
  const diff = start - now;
  if (diff <= 0) return "Under way";
  if (diff < 3600) return `In ${Math.max(1, Math.round(diff / 60))} minutes`;
  const days = daysUntil(start, now);
  const at = serverWhen(start);
  if (days === 0) return +parts(calendar, start).hour >= 17 ? `Tonight at ${at}` : `Today at ${at}`;
  if (days === 1) return `Tomorrow at ${at}`;
  if (days < 14) return `In ${days} days`;
  return `In ${Math.round(days / 7)} weeks`;
}

export function Seal({ className = "seal" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 40 40" aria-hidden="true">
      <path d="M20 2 C27 3 31 1 34 6 C38 10 37 14 38 20 C39 27 35 30 33 34 C28 39 24 37 20 38 C13 39 10 38 6 34 C2 30 3 25 2 20 C1 14 4 10 7 6 C11 2 14 3 20 2 Z" fill="#23408e" />
      <circle cx="20" cy="20" r="12.5" fill="none" stroke="#132a66" strokeWidth="2" />
      <path d="M20 9 Q21.6 18.4 31 20 Q21.6 21.6 20 31 Q18.4 21.6 9 20 Q18.4 18.4 20 9 Z" fill="#e3c170" />
    </svg>
  );
}

/** The event on the guild website's Events page, where members answer. The Companion only shows
 *  events; `event` names the one clicked (`scope/id`) so the page can bring it into view. */
export const eventUrl = (n: Notice) => `${WEBSITE}/portal/events?event=${encodeURIComponent(`${n.scope}/${n.id}`)}`;

export const openEvent = (n: Notice) => openInBrowser(eventUrl(n));
