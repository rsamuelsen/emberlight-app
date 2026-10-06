// A small, safe renderer for the Discord markdown used in announcements. It builds React elements
// only (no HTML strings), so announcement text can never inject markup into the launcher.
import type { ReactNode } from "react";

const stamp = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
const stampDay = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long" });
const stampTime = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit" });

const INLINE =
  /(\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_|~~[^~\n]+~~|`[^`\n]+`|\|\|[^|\n]+\|\||<a?:\w+:\d+>|<t:-?\d+(?::[tTdDfFR])?>|\[[^\]\n]+\]\(https:\/\/[^)\s]+\)|https:\/\/[^\s<>()]+)/;

function discordTime(token: string) {
  const [, unix, style] = /^<t:(-?\d+)(?::(\w))?>$/.exec(token)!;
  const d = new Date(Number(unix) * 1000);
  if (style === "t" || style === "T") return stampTime.format(d);
  if (style === "d" || style === "D") return stampDay.format(d);
  return stamp.format(d);
}

export function inline(text: string, openLink: (url: string) => void, key = "i"): ReactNode[] {
  const out: ReactNode[] = [];
  let rest = text;
  let n = 0;
  while (rest) {
    const m = INLINE.exec(rest);
    if (!m) {
      out.push(rest);
      break;
    }
    if (m.index) out.push(rest.slice(0, m.index));
    const t = m[0];
    const k = `${key}.${n++}`;
    const inner = (from: number, to: number) => inline(t.slice(from, t.length - to), openLink, k);
    if (t.startsWith("**")) out.push(<strong key={k}>{inner(2, 2)}</strong>);
    else if (t.startsWith("__")) out.push(<u key={k}>{inner(2, 2)}</u>);
    else if (t.startsWith("~~")) out.push(<s key={k}>{inner(2, 2)}</s>);
    else if (t.startsWith("||")) out.push(<span key={k} className="spoiler" tabIndex={0}>{inner(2, 2)}</span>);
    else if (t.startsWith("`")) out.push(<code key={k}>{t.slice(1, -1)}</code>);
    else if (t.startsWith("<t:")) out.push(<time key={k}>{discordTime(t)}</time>);
    else if (t.startsWith("<")) out.push(`:${t.split(":")[1]}:`);
    else if (t.startsWith("[")) {
      const [, label, url] = /^\[([^\]]+)\]\((.+)\)$/.exec(t)!;
      out.push(<Link key={k} url={url} openLink={openLink}>{inline(label, openLink, k)}</Link>);
    } else if (t.startsWith("https://")) out.push(<Link key={k} url={t} openLink={openLink}>{t.replace(/^https:\/\//, "")}</Link>);
    else out.push(<em key={k}>{inner(1, 1)}</em>);
    rest = rest.slice(m.index + t.length);
  }
  return out;
}

function Link({ url, openLink, children }: { url: string; openLink: (url: string) => void; children: ReactNode }) {
  return (
    <a
      href={url}
      onClick={(e) => {
        e.preventDefault();
        e.stopPropagation();
        openLink(url);
      }}
    >
      {children}
    </a>
  );
}

/** Pings ("@everyone", "@here", a role or member by id) are never shown, inline or on their own line. */
const MENTION = /@everyone\b|@here\b|<@[!&]?\d+>/g;
const stripMentions = (text: string) => text.replace(MENTION, "").replace(/[ \t]{2,}/g, " ");

/** A line that only pings people ("@Members"), which is not a title, for mention syntax stripMentions missed. */
const onlyMentions = (line: string) => {
  const words = line.trim().split(/\s+/);
  return words[0] !== "" && words.every((w) => w.startsWith("@"));
};

/** The first line with real text, as plain text, used as the announcement's title. */
export function split(rawContent: string) {
  const content = stripMentions(rawContent);
  const lines = content.split("\n");
  const first = lines.findIndex((l) => l.trim() && !onlyMentions(l));
  if (first < 0) return { title: "", body: "" };
  return { title: lines[first].replace(/^#{1,3}\s+/, "").trim(), body: lines.slice(first + 1).join("\n").trim() };
}

/** Markdown symbols removed, for one-line previews. */
export const plainText = (s: string) =>
  s
    .replace(/<t:(-?\d+)(?::\w)?>/g, (t) => discordTime(t))
    .replace(/<a?:(\w+):\d+>/g, ":$1:")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/^(#{1,3}|-#|>|[-*])\s+/gm, "")
    .replace(/(\*\*|__|~~|\|\||[*_`])/g, "")
    .replace(/\s+/g, " ")
    .trim();

export function Blocks({ text, openLink }: { text: string; openLink: (url: string) => void }) {
  const blocks: ReactNode[] = [];
  let list: ReactNode[] = [];
  const flush = () => {
    if (list.length) blocks.push(<ul key={`l${blocks.length}`}>{list}</ul>);
    list = [];
  };
  text.split("\n").forEach((line, i) => {
    const k = `b${i}`;
    const bullet = /^\s*[-*]\s+(.*)$/.exec(line);
    if (bullet) {
      list.push(<li key={k}>{inline(bullet[1], openLink, k)}</li>);
      return;
    }
    flush();
    if (!line.trim()) return;
    const heading = /^(#{1,3})\s+(.*)$/.exec(line);
    if (heading) blocks.push(<h4 key={k}>{inline(heading[2], openLink, k)}</h4>);
    else if (line.startsWith("-# ")) blocks.push(<p key={k} className="subtext">{inline(line.slice(3), openLink, k)}</p>);
    else if (line.startsWith("> ")) blocks.push(<blockquote key={k}>{inline(line.slice(2), openLink, k)}</blockquote>);
    else blocks.push(<p key={k}>{inline(line, openLink, k)}</p>);
  });
  flush();
  return <>{blocks}</>;
}
