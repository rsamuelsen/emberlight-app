import { useCallback, useEffect, useRef, useState } from "react";
import { api, type Announcement, type CharactersView, type GuildEvent } from "./api";

const FRESH_FOR = 180_000;
const message = (e: unknown) => typeof e === "string" ? e : e instanceof Error ? e.message : "Could not refresh the guild’s information.";

/** One in-flight read per resource, with account boundaries and a three-minute freshness window. */
export function useGuildData(account: string | null, signal: number) {
  const [news, setNews] = useState<{ items: Announcement[] | null; problem: string | null }>({ items: null, problem: null });
  const [official, setOfficial] = useState<GuildEvent[] | null>(null);
  const [adventures, setAdventures] = useState<GuildEvent[] | null>(null);
  const [characters, setCharacters] = useState<CharactersView | null>(null);
  const [charactersProblem, setCharactersProblem] = useState<string | null>(null);
  const cache = useRef<{ account: string | null; stamps: Record<string, number>; pending: Set<string> }>({ account: null, stamps: {}, pending: new Set() });
  const refresh = useCallback((force = false) => {
    const request = cache.current;
    if (!account || request.account !== account) return;
    const read = <T,>(key: string, action: () => Promise<T>, apply: (value: T) => void, failed?: (e: unknown) => void) => {
      if (request.pending.has(key) || (!force && Date.now() - (request.stamps[key] ?? 0) < FRESH_FOR)) return;
      request.pending.add(key);
      request.stamps[key] = Date.now();
      action().then(value => { if (cache.current === request) apply(value); }, e => { if (cache.current === request) failed?.(e); })
        .finally(() => request.pending.delete(key));
    };
    read("news", api.announcements, items => setNews({ items, problem: null }), e => setNews(n => ({ ...n, problem: message(e) })));
    read("official", () => api.guildEvents("official"), setOfficial);
    read("adventures", () => api.guildEvents("member"), setAdventures);
    read("characters", api.characters, c => { setCharacters(c); setCharactersProblem(null); }, e => setCharactersProblem(message(e)));
  }, [account]);
  useEffect(() => {
    cache.current = { account, stamps: {}, pending: new Set() };
    setNews({ items: null, problem: null }); setOfficial(null); setAdventures(null); setCharacters(null); setCharactersProblem(null);
    refresh();
    const timer = window.setInterval(() => refresh(), FRESH_FOR);
    return () => { window.clearInterval(timer); cache.current = { account: null, stamps: {}, pending: new Set() }; };
  }, [account, refresh]);
  useEffect(() => { refresh(); }, [refresh, signal]);
  return { news, official, adventures, characters, charactersProblem, refresh };
}
