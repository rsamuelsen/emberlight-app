import { openInBrowser as openLink, type Announcement } from "./api";
import { Blocks, inline, plainText, split } from "./discord";

const day = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" });
const dayLong = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });

interface ListProps {
  items: Announcement[] | null;
  signedIn: boolean;
  problem: string | null;
  limit?: number;
  selected?: string | null;
  onOpen: (id: string) => void;
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
export function NewsList({ items, signedIn, problem, limit, selected, onOpen }: ListProps) {
  const quiet = state(items, signedIn, problem);
  if (quiet || !items) return <p className="quiet">{quiet}</p>;
  return (
    <ol className="news">
      {items.slice(0, limit).map((a) => {
        const { title, body } = split(a.content);
        const preview = plainText(body);
        return (
          <li key={a.id}>
            <button type="button" className={`news-row${selected === a.id ? " is-selected" : ""}`} aria-current={selected === a.id} onClick={() => onOpen(a.id)}>
              <span className="news-date">{day.format(a.createdAt * 1000)}</span>
              <span className="news-title">{title ? plainText(title) : "Announcement"}</span>
              {preview && <span className="news-preview">{preview}</span>}
            </button>
          </li>
        );
      })}
    </ol>
  );
}

/** The full announcements page: the list on the left, the chosen one in full on the right. */
export function NewsReader({ items, signedIn, problem, selected, onOpen }: ListProps) {
  const quiet = state(items, signedIn, problem);
  if (quiet || !items) {
    return (
      <div className="page-empty">
        <p>{quiet}</p>
      </div>
    );
  }
  const current = items.find((a) => a.id === selected) ?? items[0];
  const { title, body } = split(current.content);
  return (
    <div className="reader">
      <div className="reader-list">
        <NewsList items={items} signedIn={signedIn} problem={problem} selected={current.id} onOpen={onOpen} />
      </div>
      <article className="reader-page" key={current.id}>
        <p className="reader-date">{dayLong.format(current.createdAt * 1000)}</p>
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
