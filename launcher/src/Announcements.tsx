import { useEffect } from "react";
import { openInBrowser as openLink, type Announcement } from "./api";
import { Blocks, inline, plainText, split } from "./discord";
import { SERVER_TIME_ZONE, serverWhen } from "./events";
import { Arrow, EmptyState } from "./UI";

const day = new Intl.DateTimeFormat("en-GB", { timeZone: SERVER_TIME_ZONE, day: "numeric", month: "short" });

interface ListProps {
  items: Announcement[] | null;
  signedIn: boolean;
  problem: string | null;
  limit?: number;
  selected?: string | null;
  onOpen: (id: string) => void;
  isUnread?: (a: Announcement) => boolean;
  onViewed?: (a: Announcement) => void;
  /** Shows a "Mark as read" button under each unread announcement. */
  onMarkRead?: (a: Announcement) => void;
}

/** Waiting, empty or failed states, shared by the list and the reader. */
function state(items: Announcement[] | null, signedIn: boolean, problem: string | null) {
  if (!signedIn) return "Sign in to see the guild's announcements.";
  if (problem) return problem;
  if (!items) return "Fetching announcements...";
  if (!items.length) return "No announcements yet.";
  return null;
}

/** Announcements from the guild's Discord: date, title and a short preview. */
export function NewsList({ items, signedIn, problem, limit, selected, onOpen, isUnread, onMarkRead }: ListProps) {
  const quiet = state(items, signedIn, problem);
  if (quiet || !items) return <EmptyState title={quiet ?? "Fetching announcements…"} problem={signedIn && !!problem} />;
  return (
    <ol className="news">
      {items.slice(0, limit).map((a) => {
        const { title, body } = split(a.content);
        const preview = plainText(body);
        return (
          <li key={a.id}>
            <button type="button" className={`news-row${selected === a.id ? " is-selected" : ""}${isUnread?.(a) ? " is-unread" : ""}`} aria-current={selected === a.id} onClick={() => onOpen(a.id)}>
              <span className="news-date">{day.format(a.createdAt * 1000)}</span>
              <span className="news-title">{title ? plainText(title) : "Announcement"}</span>
              <Arrow />
              {preview && <span className="news-preview">{preview}</span>}
            </button>
            {onMarkRead && isUnread?.(a) && <button type="button" className="news-mark" aria-label={`Mark "${title ? plainText(title) : "Announcement"}" as read`} onClick={() => onMarkRead(a)}>Mark as read</button>}
          </li>
        );
      })}
    </ol>
  );
}

/** The full announcements page: the list on the left, the chosen one in full on the right. */
export function NewsReader({ items, signedIn, problem, selected, onOpen, isUnread, onViewed }: ListProps) {
  const viewed = items?.find(a => a.id === selected) ?? items?.[0];
  useEffect(() => { if (signedIn && !problem && viewed) onViewed?.(viewed); }, [signedIn, problem, viewed, onViewed]);
  const quiet = state(items, signedIn, problem);
  if (quiet || !items) {
    return (
      <div className="page-empty">
        <EmptyState title={quiet ?? "Fetching announcements…"} problem={signedIn && !!problem} />
      </div>
    );
  }
  const current = items.find((a) => a.id === selected) ?? items[0];
  const { title, body } = split(current.content);
  return (
    <div className="reader">
      <nav className="reader-list" aria-label="Announcements">
        <NewsList items={items} signedIn={signedIn} problem={problem} selected={current.id} onOpen={onOpen} isUnread={isUnread} onMarkRead={onViewed} />
      </nav>
      <article tabIndex={0} aria-label="Selected announcement" className="reader-page" key={current.id}>
        <p className="reader-date">{serverWhen(current.createdAt, true)}</p>
        <h2 className="reader-title">{title ? inline(title, openLink) : "Announcement"}</h2>
        <div className="news-body">
          <Blocks text={body} openLink={openLink} />
        </div>
        <p className="news-foot">
          <span>{current.author}</span>
          <a
            href={current.url}
            onClick={(e) => {
              e.preventDefault();
              openLink(current.url);
            }}
          >
            Open in Discord
          </a>
        </p>
      </article>
    </div>
  );
}
