import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Agenda, type EventsView } from "./Agenda";
import { NewsReader } from "./Announcements";
import { api, eventAsNotice, inTauri, type Announcement, type GuildEvent, type CharactersView, type LauncherUpdate, type Notice, type Overview } from "./api";
import { adventures, officialEvents, openEvent, useNow } from "./events";
import { Home } from "./Home";
import { checkNotifications } from "./notifications";
import { Lantern, type LanternMood } from "./Lantern";
import { Scene, type RoadState } from "./Scene";
import { Characters } from "./Characters";
import { Settings } from "./Settings";
import { StatusCard } from "./StatusCard";
import { setupDone, setupState, Welcome } from "./Welcome";
import crest from "./assets/crest.png";

const clock = new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit" });
const day = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short" });
const message = (e: unknown) => (typeof e === "string" ? e : e instanceof Error ? e.message : "Something went wrong.");

type Page = "home" | "events" | "characters" | "news" | "settings";
const ICONS: Record<Page, string> = {
  home: "M3 10.5 10 4l7 6.5M5 9v8h10V9",
  events: "M4 4h12v13H4zM4 7h12M7 2v3M13 2v3",
  characters: "M10 3a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM3.5 17.5c1-3.6 3.6-5.5 6.5-5.5s5.5 1.9 6.5 5.5",
  news: "M3 7l9-4v14l-9-4zM12 6a4 4 0 0 1 0 8",
  settings: "M10 7a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM10 2v2.3M10 15.7V18M4.2 4.2l1.6 1.6M14.2 14.2l1.6 1.6M2 10h2.3M15.7 10H18M4.2 15.8l1.6-1.6M14.2 5.8l1.6-1.6",
};
const PAGES: [Page, string][] = [
  ["home", "Home"],
  ["events", "Events"],
  ["characters", "Characters"],
  ["news", "Announcements"],
];
const PAGE_NAME: Record<Page, string> = { home: "Home", events: "Events", characters: "Characters", news: "Announcements", settings: "Settings" };

function syncedAt(at: number) {
  const d = new Date(at * 1000);
  return new Date().toDateString() === d.toDateString() ? clock.format(d) : `${day.format(d)}, ${clock.format(d)}`;
}

async function windowAction(action: "minimize" | "startDragging") {
  if (!inTauri) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow()[action]();
}

export function App() {
  const [overview, setOverview] = useState<Overview | null>(null);
  const [busy, setBusy] = useState<"sync" | "play" | "addon" | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [page, setPage] = useState<Page>("home");
  const openSettings = () => setPage("settings");
  const [eventsView, setEventsView] = useState<EventsView>("guild");
  // The first-run guide: decided once, when the app opens, and shown until the member leaves it.
  const [guide, setGuide] = useState<boolean | null>(null);
  const [newsId, setNewsId] = useState<string | null>(null);
  const now = useNow();

  // Counts every refresh, so what is read from the server alongside the overview is read again too.
  const [refreshed, setRefreshed] = useState(0);
  const refresh = useCallback(() => {
    api.overview().then(setOverview, (e) => setProblem(message(e)));
    setRefreshed((n) => n + 1);
  }, []);

  useEffect(() => {
    if (!import.meta.env.DEV || inTauri) return;
    import("./dev-mock").then(({ previewView, previewPage }) => {
      if (previewView === "ledger") setPage("settings");
      if (previewView === "characters") setPage("characters");
      if (previewPage === "events" || previewPage === "characters" || previewPage === "news" || previewPage === "settings") setPage(previewPage);
      if (new URLSearchParams(location.search).get("state") === "syncing") act("sync", api.syncNow);
    });
  }, []);

  useEffect(() => {
    refresh();
    window.addEventListener("focus", refresh);
    let unlisten: (() => void) | undefined;
    if (inTauri) {
      import("@tauri-apps/api/event").then(({ listen }) => listen("overview-changed", refresh)).then((u) => (unlisten = u));
    }
    return () => {
      window.removeEventListener("focus", refresh);
      unlisten?.();
    };
  }, [refresh]);

  const [news, setNews] = useState<{ items: Announcement[] | null; problem: string | null }>({ items: null, problem: null });
  const signedInNow = overview?.signedIn ?? false;

  // The member's name and Discord id, read again once each time the app opens signed in.
  const accountRead = useRef(false);
  useEffect(() => {
    if (!signedInNow || accountRead.current) return;
    accountRead.current = true;
    api.refreshAccount().then(setOverview, () => undefined);
  }, [signedInNow]);

  // Sign in and out from the title bar as well as from Settings.
  const [signingIn, setSigningIn] = useState(false);
  const titleSignIn = async () => {
    setSigningIn(true);
    setProblem(null);
    try {
      setOverview(await api.signInDiscord());
    } catch (e) {
      setProblem(message(e));
    } finally {
      setSigningIn(false);
    }
  };
  const titleSignOut = () => api.signOut().then(setOverview, (e) => setProblem(message(e)));
  const lastSyncAt = overview?.lastSync?.at;
  useEffect(() => {
    if (!signedInNow) {
      setNews({ items: null, problem: null });
      return;
    }
    let live = true;
    const load = () =>
      api.announcements().then(
        (items) => live && setNews({ items, problem: null }),
        (e) => live && setNews((n) => ({ items: n.items, problem: n.items ? null : message(e) })),
      );
    load();
    const timer = window.setInterval(load, 5 * 60 * 1000);
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [signedInNow, lastSyncAt]);

  // The guild's official events, read from the server like the website does. Until that answers
  // (or while it cannot be reached) the events in the game's synced file stand in.
  // Members' adventures come the same way, kept apart from the official events.
  const [serverEvents, setServerEvents] = useState<Notice[] | null>(null);
  const [serverAdventures, setServerAdventures] = useState<Notice[] | null>(null);
  const [officialRaw, setOfficialRaw] = useState<GuildEvent[] | null>(null);
  useEffect(() => {
    if (!signedInNow) {
      setServerEvents(null);
      setServerAdventures(null);
      return;
    }
    let live = true;
    const load = () => {
      api.guildEvents("official").then(
        (items) => {
          if (!live) return;
          setServerEvents(items.map(eventAsNotice));
          setOfficialRaw(items);
        },
        () => undefined,
      );
      api.guildEvents("member").then(
        (items) => live && setServerAdventures(items.map(eventAsNotice)),
        () => undefined,
      );
    };
    load();
    const timer = window.setInterval(load, 5 * 60 * 1000);
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [signedInNow, lastSyncAt, refreshed]);

  // Windows notifications: a new guild event, or one the member joins starting within the hour.
  useEffect(() => {
    if (officialRaw) checkNotifications(officialRaw, now);
  }, [officialRaw, now]);

  // The member's characters, for the status card and Settings. Read again when Settings opens,
  // when the window gets focus and when the game starts or closes: an officer may have answered a
  // request meanwhile, or a newly played character may be on this computer.
  const [characters, setCharacters] = useState<CharactersView | null>(null);
  const inSettings = page === "settings" || page === "characters";
  useEffect(() => {
    if (!signedInNow) {
      setCharacters(null);
      return;
    }
    let live = true;
    api.characters().then(
      (c) => live && setCharacters(c),
      () => undefined,
    );
    return () => {
      live = false;
    };
  }, [signedInNow, inSettings, refreshed]);

  // When the launcher opens: update the addon if the guild published a newer version (at most
  // hourly), then sync, unless the game is running or it synced a moment ago.
  const opened = useRef(false);
  const [addonNote, setAddonNote] = useState<string | null>(null);
  const [launcherUpdate, setLauncherUpdate] = useState<LauncherUpdate | null>(null);
  useEffect(() => {
    if (!overview || opened.current) return;
    opened.current = true;
    const nowSecs = Date.now() / 1000;
    const idle = !overview.watching && !overview.wow.gameRunning && !overview.wow.problem;
    const due = !!overview.addon.installed && !overview.wow.problem && !(overview.lastAddonCheck && nowSecs - overview.lastAddonCheck.at < 3600);
    const recent = overview.lastSync && nowSecs - overview.lastSync.at < 300;
    const sync = idle && overview.signedIn && !recent;
    (async () => {
      if (due) await addonUpdate(overview, idle);
      if (sync) await act("sync", api.syncNow);
      // Last, and quietly: a newer launcher is offered, never installed without asking.
      api.launcherUpdate().then(setLauncherUpdate, () => undefined);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [overview]);

  /** Installs a newer addon by itself when the member allows it and the game is closed;
   *  otherwise only looks, so the versions card can say a new version is ready. */
  async function addonUpdate(o: Overview, idle: boolean) {
    if (idle && o.settings.autoUpdateAddon) {
      const before = o.addon.installed;
      const after = await act("addon", api.updateAddon, true);
      if (after && after.addon.installed !== before && after.lastAddonCheck) setAddonNote(after.lastAddonCheck.message);
    } else {
      await act("addon", api.checkAddon, true);
    }
  }

  // While the app keeps running (in the tray, for days), look again every four hours.
  const latest = useRef(overview);
  latest.current = overview;
  useEffect(() => {
    const timer = window.setInterval(() => {
      const o = latest.current;
      if (!o) return;
      if (o.addon.installed && !o.wow.problem) addonUpdate(o, !o.watching && !o.wow.gameRunning);
      api.launcherUpdate().then(setLauncherUpdate, () => undefined);
    }, 4 * 60 * 60 * 1000);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** Runs an action; a quiet one (the automatic addon check) keeps its failure in Settings only. */
  async function act(kind: "sync" | "play" | "addon", action: () => Promise<Overview>, quiet = false) {
    setBusy(kind);
    setProblem(null);
    try {
      const next = await action();
      setOverview(next);
      return next;
    } catch (e) {
      if (!quiet) setProblem(message(e));
      if (quiet) refresh();
      return null;
    } finally {
      setBusy(null);
    }
  }

  const [updatingLauncher, setUpdatingLauncher] = useState(false);
  const installLauncher = async () => {
    setUpdatingLauncher(true);
    setProblem(null);
    try {
      await api.installLauncherUpdate();
    } catch (e) {
      setProblem(message(e));
      setUpdatingLauncher(false);
    }
  };

  const installAddon = async () => {
    setAddonNote(null);
    const after = await act("addon", api.updateAddon);
    if (after?.lastAddonCheck) setAddonNote(after.lastAddonCheck.message);
  };

  const events = useMemo(() => serverEvents ?? officialEvents(overview?.notices ?? []), [serverEvents, overview?.notices]);
  const adventureList = useMemo(() => adventures(serverAdventures ?? overview?.notices ?? [], now), [serverAdventures, overview?.notices, now]);
  useEffect(() => {
    if (import.meta.env.DEV && new URLSearchParams(location.search).get("view") === "news") setPage("news");
  }, []);

  useEffect(() => {
    if (!overview || guide !== null) return;
    const forced = import.meta.env.DEV && new URLSearchParams(location.search).get("view") === "setup";
    const ready = setupState(overview, null);
    setGuide(forced || (!setupDone() && !(ready.folder && ready.addon && ready.account)));
  }, [overview, guide]);

  if (!overview) return <div className="frame is-loading" />;
  const { wow, signedIn, settings, lastSync } = overview;

  const cold = !wow.root || !!wow.problem;
  const needsSetup = cold || !overview.addon.installed || !signedIn;
  const inGame = overview.watching || wow.gameRunning;
  const mood: LanternMood = busy === "play" ? "busy" : inGame ? "ingame" : cold ? "cold" : "lit";
  const label = busy === "play" ? "Starting" : inGame ? "In game" : "Play";
  const hint = cold
    ? "Choose your World of Warcraft folder in Settings."
    : !overview.addon.installed && !inGame
      ? "The Emberlight addon is not installed in this game version."
      : null;

  const road: RoadState = !signedIn ? "dark" : busy ? "syncing" : lastSync?.error ? "error" : lastSync ? "synced" : "idle";
  const syncLine = busy === "addon"
    ? "Checking the addon"
    : busy === "sync" || busy === "play"
      ? "Syncing"
      : !signedIn
        ? "Not signed in"
        : lastSync?.error
          ? `Sync failed. ${lastSync.error}`
          : lastSync
            ? `Synced at ${syncedAt(lastSync.at)}`
            : "Not synced yet";
  const note = !busy && signedIn && !lastSync?.error ? lastSync?.note ?? (lastSync?.rejected.length ? `${lastSync.rejected.length} notice(s) were not accepted.` : null) : null;
  const planned = events.filter((n) => !n.cancelled).length;
  // A mark on Characters only when something needs a look: a refusal, or a request still waiting.
  const characterMark = characters?.mine.some((c) => c.status === "refused")
    ? "refused"
    : characters?.mine.some((c) => c.status === "pending")
      ? "pending"
      : null;

  const play = () => (cold ? openSettings() : inGame || busy === "addon" ? undefined : act("play", api.play));
  const openNews = (id: string | null) => {
    setNewsId(id);
    setPage("news");
  };

  return (
    <div className="frame">
      <header className="titlebar" data-tauri-drag-region>
        <img className="titlebar-crest" src={crest} alt="" data-tauri-drag-region />
        <span className="titlebar-name" data-tauri-drag-region>
          Emberlight <span className="titlebar-sub">Companion</span>
        </span>
        <span className="titlebar-space" data-tauri-drag-region />
        {!guide && (
          <div className="titlebar-account">
            {signedIn ? (
              <>
                <span className="titlebar-member">{settings.memberName ?? "Signed in"}</span>
                <button className="titlebar-button" onClick={titleSignOut}>
                  Sign out
                </button>
              </>
            ) : signingIn ? (
              <button className="titlebar-button" onClick={() => api.cancelSignIn()}>
                Cancel sign-in
              </button>
            ) : (
              <button className="titlebar-button is-primary" disabled={!settings.server} onClick={titleSignIn}>
                Sign in with Discord
              </button>
            )}
          </div>
        )}
        <button className="stud" aria-label="Minimise" onClick={() => windowAction("minimize")}>
          <svg viewBox="0 0 12 12" aria-hidden="true">
            <path d="M2.5 6.5 H9.5" />
          </svg>
        </button>
        <button className="stud" aria-label="Close" onClick={() => (inTauri ? api.closeWindow() : undefined)}>
          <svg viewBox="0 0 12 12" aria-hidden="true">
            <path d="M3 3 L9 9 M9 3 L3 9" />
          </svg>
        </button>
      </header>

      {guide ? (
        <Welcome overview={overview} onUpdate={setOverview} characters={characters} onDone={() => setGuide(false)} />
      ) : (
        <>
      <aside className="side">
        <Scene road={road} />
        <nav className="rail-nav" aria-label="Pages">
          {PAGES.map(([id, name]) => (
            <button key={id} className={`rail-nav-item${page === id ? " is-current" : ""}`} aria-current={page === id ? "page" : undefined} onClick={() => setPage(id)}>
              <svg viewBox="0 0 20 20" aria-hidden="true">
                <path d={ICONS[id]} />
              </svg>
              <span>{name}</span>
              {id === "events" && planned > 0 && <span className="tab-count">{planned}</span>}
              {id === "characters" && characterMark && (
                <span className={`rail-dot${characterMark === "refused" ? " is-problem" : ""}`} title={characterMark === "refused" ? "A request was not approved" : "Waiting for an officer"} />
              )}
            </button>
          ))}
          <button className={`rail-nav-item${page === "settings" ? " is-current" : ""}`} aria-current={page === "settings" ? "page" : undefined} onClick={() => setPage("settings")}>
            <svg viewBox="0 0 20 20" aria-hidden="true">
              <path d={ICONS.settings} />
            </svg>
            <span>Settings</span>
          </button>
        </nav>
        <StatusCard
          overview={overview}
          busy={!!busy}
          onInstall={installAddon}
          onSettings={openSettings}
          launcherUpdate={launcherUpdate}
          updatingLauncher={updatingLauncher}
          onUpdateLauncher={installLauncher}
        />
        <div className="hearth">
          <Lantern mood={mood} label={label} hint={hint} onPress={play} />
          <div className="status" role="status" aria-live="polite">
            <p className={`status-sync${lastSync?.error && !busy ? " is-problem" : ""}`}>{syncLine}</p>
            {note && <p className="status-note">{note}</p>}
            {addonNote && !busy && <p className="status-note">{addonNote}</p>}
            {problem && <p className="status-note is-problem">{problem}</p>}
            {signedIn && (
              <p className="status-actions">
                <button className="link" disabled={!!busy} onClick={() => act("sync", api.syncNow)}>
                  Sync now
                </button>
              </p>
            )}
          </div>
        </div>
      </aside>

      <main className="hall">
        <div className="topbar">
          <h1>
            {PAGE_NAME[page]}
            {page === "events" && planned > 0 && <span className="tab-count">{planned}</span>}
          </h1>
        </div>
        <div className="hall-page" key={page}>
          {page === "home" && (needsSetup ? (
            <div className="home">
              <div className="section-head">
                <h2>Setup is not finished</h2>
              </div>
              <p className="set-intro">
                {cold ? "The game folder is not set." : !overview.addon.installed ? "The Emberlight addon is not installed." : "You are not signed in."} The guide
                takes you through what is left.
              </p>
              <button className="btn" onClick={() => setGuide(true)}>
                Continue setup
              </button>
            </div>
          ) : (
            <Home
              events={events}
              adventures={adventureList}
              now={now}
              signedIn={signedIn}
              announcements={news.items}
              newsProblem={news.problem}
              onRead={openEvent}
              onNews={openNews}
              onEvents={(which) => {
                setEventsView(which);
                setPage("events");
              }}
            />
          ))}
          {page === "events" && (
            <Agenda
              view={eventsView}
              onView={setEventsView}
              events={eventsView === "guild" ? events : adventureList}
              now={now}
              signedIn={signedIn}
              onRead={openEvent}
            />
          )}
          {page === "characters" && <Characters characters={characters} signedIn={signedIn} />}
          {page === "news" && <NewsReader items={news.items} signedIn={signedIn} problem={news.problem} selected={newsId} onOpen={setNewsId} />}
          {page === "settings" && (
            <Settings
              overview={overview}
              onUpdate={setOverview}
              launcherUpdate={launcherUpdate}
              onLauncherUpdate={setLauncherUpdate}
            />
          )}
        </div>
      </main>
        </>
      )}
    </div>
  );
}
