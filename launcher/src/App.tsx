import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Agenda, type EventsView } from "./Agenda";
import { NewsReader } from "./Announcements";
import { api, eventAsNotice, inTauri, type Announcement, type LauncherUpdate, type UpdateProgress, type Notice, type Overview } from "./api";
import { adventures, officialEvents, fmtTime, useNow } from "./events";
import { Home } from "./Home";
import { checkNotifications, clearReminderSession } from "./notifications";
import { Lantern, type LanternMood } from "./Lantern";
import { Scene, type RoadState } from "./Scene";
import { Characters } from "./Characters";
import { Settings } from "./Settings";
import { StatusCard } from "./StatusCard";
import { setupDone, setupState, Welcome } from "./Welcome";
import { useGuildData } from "./useGuildData";
import { EventDetails } from "./EventDetails";
import { announcementUnread, markAnnouncementRead } from "./readMarks";
import { syncSummary, syncRecovery } from "./syncStatus";
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
const PAGE_DESCRIPTION: Record<Page, string> = {
  home: "Events, announcements and members’ adventures.",
  events: "Find your next gathering with the guild.",
  characters: "Your linked characters and verification requests.",
  news: "The latest from the guild’s Discord.",
  settings: "Your account, game and Companion preferences.",
};
const PAGE_NAME: Record<Page, string> = { home: "Home", events: "Events", characters: "Characters", news: "Announcements", settings: "Settings" };

function syncedAt(at: number) {
  const d = new Date(at * 1000);
  return new Date().toDateString() === d.toDateString() ? clock.format(d) : `${day.format(d)}, ${clock.format(d)}`;
}

async function windowAction(action: "minimize" | "startDragging" | "toggleMaximize") {
  if (!inTauri) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow()[action]();
}

function WindowButtons() {
  const [maximized, setMaximized] = useState(false);
  useEffect(() => {
    if (!inTauri) return;
    let unlisten: (() => void) | undefined;
    let disposed = false;
    import("@tauri-apps/api/window").then(async ({ getCurrentWindow }) => {
      const window = getCurrentWindow();
      const update = () => window.isMaximized().then(value => { if (!disposed) setMaximized(value); });
      await update();
      const stop = await window.onResized(update);
      if (disposed) stop(); else unlisten = stop;
    });
    return () => { disposed = true; unlisten?.(); };
  }, []);
  return (
    <>
      <button className="stud" aria-label="Minimise" onClick={() => windowAction("minimize")}>
        <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6.5 H9.5" /></svg>
      </button>
      <button className="stud" aria-label={maximized ? "Restore window" : "Maximise"} onClick={() => windowAction("toggleMaximize")}>
        <svg viewBox="0 0 12 12" aria-hidden="true"><path d={maximized ? "M4 2h6v6M2 4h6v6H2z" : "M2 2h8v8H2z"} /></svg>
      </button>
      <button className="stud stud-close" aria-label="Close" onClick={() => (inTauri ? api.closeWindow() : undefined)}>
        <svg viewBox="0 0 12 12" aria-hidden="true"><path d="M3 3 L9 9 M9 3 L3 9" /></svg>
      </button>
    </>
  );
}

export function App() {
  const [overview, setOverview] = useState<Overview | null>(null);
  const authEpoch = useRef(0);
  const signingOut = useRef(false);
  const applyOverview = (next: Overview) => { if (!signingOut.current) setOverview(next); };
  const [busy, setBusy] = useState<"sync" | "play" | "addon" | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [page, setPage] = useState<Page>("home");
  const openSettings = () => setPage("settings");
  const [eventsView, setEventsView] = useState<EventsView>("guild");
  // The first-run guide: decided once, when the app opens, and shown until the member leaves it.
  const [guide, setGuide] = useState<boolean | null>(null);
  const [newsId, setNewsId] = useState<string | null>(null);
  const now = useNow();
  const [selectedEvent, setSelectedEvent] = useState<Notice | null>(null);
  const [foreground, setForeground] = useState(() => !document.hidden && document.hasFocus());
  const [, setReadRevision] = useState(0);
  const [notificationRevision, setNotificationRevision] = useState(0);
  const [launchProgress, setLaunchProgress] = useState<UpdateProgress | null>(null);
  useEffect(() => {
    const update = () => setForeground(!document.hidden && document.hasFocus());
    window.addEventListener("focus", update); window.addEventListener("blur", update); document.addEventListener("visibilitychange", update);
    const notificationSettings = () => setNotificationRevision(n => n + 1);
    window.addEventListener("emberlight-notification-settings", notificationSettings);
    return () => { window.removeEventListener("focus", update); window.removeEventListener("blur", update); document.removeEventListener("visibilitychange", update); window.removeEventListener("emberlight-notification-settings", notificationSettings); };
  }, []);

  // Each overview refresh also asks the guild-data cache to refresh stale information.
  const [refreshed, setRefreshed] = useState(0);
  const overviewRead = useRef<Promise<void> | null>(null);
  const refresh = useCallback(() => {
    if (overviewRead.current) return overviewRead.current;
    const epoch = authEpoch.current;
    const read = api.overview().then(next => { if (epoch === authEpoch.current && !signingOut.current) setOverview(next); }, e => setProblem(message(e))).finally(() => { overviewRead.current = null; });
    overviewRead.current = read;
    setRefreshed(n => n + 1);
    return read;
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
    let disposed = false;
    let unlisten: (() => void) | undefined;
    if (inTauri) {
      import("@tauri-apps/api/event").then(async ({ listen }) => {
        const stops = await Promise.all([listen("overview-changed", refresh), listen<boolean>("window-activity", ({ payload }) => setForeground(payload))]);
        const stop = () => stops.forEach(fn => fn());
        if (disposed) stop(); else unlisten = stop;
      });
    }
    return () => { disposed = true; window.removeEventListener("focus", refresh); unlisten?.(); };
  }, [refresh]);

  const signedInNow = overview?.signedIn ?? false;
  const account = signedInNow ? overview?.settings.discordId ?? overview?.settings.memberName ?? "signed-in" : null;
  const notificationAccount = signedInNow ? overview?.settings.discordId ?? null : null;
  const guild = useGuildData(account, refreshed);
  const { news, characters, charactersProblem, official: officialRaw } = guild;
  const serverEvents = useMemo(() => guild.official?.map(eventAsNotice) ?? null, [guild.official]);
  const serverAdventures = useMemo(() => guild.adventures?.map(eventAsNotice) ?? null, [guild.adventures]);
  const accountRead = useRef(false);
  useEffect(() => {
    if (!signedInNow) { accountRead.current = false; clearReminderSession(); setSelectedEvent(null); return; }
    if (!accountRead.current) { accountRead.current = true; const epoch = authEpoch.current; api.refreshAccount().then(next => { if (epoch === authEpoch.current && !signingOut.current) setOverview(next); }, () => undefined); }
  }, [signedInNow]);
  useEffect(() => { clearReminderSession(); }, [notificationAccount]);
  useEffect(() => { if (officialRaw && notificationAccount) void checkNotifications(officialRaw, now, notificationAccount); }, [officialRaw, now, notificationAccount, notificationRevision]);
  const [signingIn, setSigningIn] = useState(false);
  const titleSignIn = async () => {
    if (signingOut.current) return false;
    setSigningIn(true); setProblem(null);
    try { setOverview(await api.signInDiscord()); return true; } catch (e) { setProblem(message(e)); return false; } finally { setSigningIn(false); }
  };
  // "Sign in again" after a failed sync: sign in, then sync at once, so the member sees a fresh result.
  const signInAndSync = async () => { if (await titleSignIn()) await act("sync", api.syncNow); };
  const titleSignOut = async () => {
    signingOut.current = true; authEpoch.current++;
    clearReminderSession(); setSelectedEvent(null);
    setOverview(o => o ? { ...o, signedIn: false } : o);
    try { const next = await api.signOut(); setOverview(next); return next; }
    catch (e) { refresh(); throw e; }
    finally { signingOut.current = false; }
  };
  const markRead = useCallback((item: Announcement) => { if (markAnnouncementRead(notificationAccount, item)) setReadRevision(n => n + 1); }, [notificationAccount]);
  const isUnread = (item: Announcement) => announcementUnread(notificationAccount, item);

  // When the launcher opens: update the addon if the guild published a newer version (at most
  // hourly), then sync, unless the game is running or it synced a moment ago.
  const opened = useRef(false);
  const [addonNote, setAddonNote] = useState<string | null>(null);
  const [launcherUpdate, setLauncherUpdate] = useState<LauncherUpdate | null>(null);
  const [launcherChecked, setLauncherChecked] = useState(false);
  const launcherResult = (update: LauncherUpdate | null) => { setLauncherUpdate(update); setLauncherChecked(true); };
  useEffect(() => {
    if (!overview || opened.current) return;
    opened.current = true;
    const nowSecs = Date.now() / 1000;
    const idle = !overview.watching && !overview.wow.gameRunning && !overview.wow.problem;
    // After the move off the finished beta the addon may be missing in Forever: put it there too.
    const wanted = !!overview.addon.installed || !!(overview.settings.installAddonAfterMove && overview.settings.autoUpdateAddon);
    const due = wanted && !overview.wow.problem && !(overview.lastAddonCheck && nowSecs - overview.lastAddonCheck.at < 3600);
    const recent = overview.lastSync && nowSecs - overview.lastSync.at < 300;
    const sync = idle && overview.signedIn && !recent;
    (async () => {
      if (due) await addonUpdate(overview, idle);
      if (sync) await act("sync", api.syncNow);
      // Last, and quietly: a newer launcher is offered, never installed without asking.
      api.launcherUpdate().then(launcherResult, () => undefined);
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
      if ((o.addon.installed || o.settings.installAddonAfterMove) && !o.wow.problem) addonUpdate(o, !o.watching && !o.wow.gameRunning);
      api.launcherUpdate().then(launcherResult, () => undefined);
    }, 4 * 60 * 60 * 1000);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** Runs an action; a quiet one (the automatic addon check) keeps its failure in Settings only. */
  async function act(kind: "sync" | "play" | "addon", action: () => Promise<Overview>, quiet = false) {
    setBusy(kind);
    setProblem(null);
    try {
      const epoch = authEpoch.current;
      const next = await action();
      if (epoch === authEpoch.current && !signingOut.current) setOverview(next);
      if (kind === "sync") guild.refresh(true);
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

  useEffect(() => {
    if (!inTauri) return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    import("@tauri-apps/api/event").then(({ listen }) => listen<UpdateProgress>("launcher-update-progress", ({ payload }) => {
      setLaunchProgress(payload); setUpdatingLauncher(payload.stage !== "failed");
    })).then(stop => { if (disposed) stop(); else unlisten = stop; });
    return () => { disposed = true; unlisten?.(); };
  }, []);

  const installAddon = async () => {
    setAddonNote(null);
    const after = await act("addon", api.updateAddon);
    if (after?.lastAddonCheck) setAddonNote(after.lastAddonCheck.message);
  };

  const events = useMemo(() => serverEvents ?? officialEvents(overview?.notices ?? []), [serverEvents, overview?.notices]);
  const adventureList = useMemo(() => adventures(serverAdventures ?? overview?.notices ?? [], now), [serverAdventures, overview?.notices, now]);
  useEffect(() => {
    const next = signedInNow ? events.find(n => !n.cancelled && n.start > now) : null;
    api.updateTray(next ? "Next event: " + next.title : null).catch(() => undefined);
  }, [events, signedInNow, now]);
  useEffect(() => {
    if (import.meta.env.DEV && new URLSearchParams(location.search).get("view") === "news") setPage("news");
  }, []);

  useEffect(() => {
    if (!overview || guide !== null) return;
    const forced = import.meta.env.DEV && new URLSearchParams(location.search).get("view") === "setup";
    const ready = setupState(overview, null);
    setGuide(forced || (!setupDone() && !(ready.folder && ready.addon && ready.account)));
  }, [overview, guide]);

  if (!overview) return (
    <div className="frame is-loading">
      <header className="titlebar" data-tauri-drag-region>
        <img className="titlebar-crest" src={crest} alt="" data-tauri-drag-region />
        <span className="titlebar-name" data-tauri-drag-region>Emberlight <span className="titlebar-sub" data-tauri-drag-region>Companion</span></span>
        <span className="titlebar-space" data-tauri-drag-region />
        <WindowButtons />
      </header>
      <img src={crest} alt="" width="64" height="64" />
      <p role="status">{problem ? "Could not open Emberlight Companion." : "Opening Emberlight Companion…"}</p>
      {problem && <><p className="loading-problem">{problem}</p><button className="btn" onClick={refresh}>Try again</button></>}
    </div>
  );
  const { wow, signedIn, settings, lastSync } = overview;

  const cold = !wow.root || !!wow.problem;
  const needsSetup = cold || !overview.addon.installed || !signedIn;
  const inGame = overview.watching || wow.gameRunning;
  const mood: LanternMood = busy === "play" ? "busy" : inGame ? "ingame" : cold ? "cold" : "lit";
  const waiting = overview.launchState === "waiting" || overview.launchState === "starting";
  const label = busy === "play" || overview.launchState === "starting" ? "Starting the game" : inGame ? "In game" : waiting ? "Waiting for the game" : overview.launchProblem ? "Try again" : "Play";
  const hint = cold
    ? "Choose your World of Warcraft folder in Settings."
    : !overview.addon.installed && !inGame
      ? "The Emberlight addon is not installed in this game version."
      : null;

  const road: RoadState = !signedIn ? "dark" : busy === "sync" || busy === "play" ? "syncing" : lastSync?.error ? "error" : lastSync ? "synced" : "idle";
  const syncLine = busy === "addon"
    ? "Checking the addon"
    : busy === "sync" || busy === "play"
      ? "Syncing"
      : !signedIn
        ? "Not signed in"
        : lastSync?.error
          ? "Could not sync"
          : lastSync
            ? `Synced at ${syncedAt(lastSync.at)}`
            : "Not synced yet";
  const recovery = syncRecovery(lastSync);
  const note = !busy && signedIn && !lastSync?.error ? lastSync?.note ?? (lastSync?.rejected.length ? `${lastSync.rejected.length} update${lastSync.rejected.length === 1 ? " was" : "s were"} not accepted.` : null) : null;
  const planned = events.filter((n) => !n.cancelled).length;
  // A mark on Characters only when something needs a look: a refusal, or a request still waiting.
  const characterMark = characters?.mine.some((c) => c.status === "refused")
    ? "refused"
    : characters?.mine.some((c) => c.status === "pending")
      ? "pending"
      : null;

  const play = () => (cold ? openSettings() : inGame || busy || waiting ? undefined : act("play", api.play));
  const openNews = (id: string | null) => {
    setNewsId(id);
    setPage("news");
  };

  return (
    <div className={`frame${!foreground || inGame ? " is-resting" : ""}`}>
      <header className="titlebar" data-tauri-drag-region>
        <img className="titlebar-crest" src={crest} alt="" data-tauri-drag-region />
        <span className="titlebar-name" data-tauri-drag-region>
          Emberlight <span className="titlebar-sub" data-tauri-drag-region>Companion</span>
        </span>
        <span className="titlebar-space" data-tauri-drag-region />
        <time className="server-clock" data-tauri-drag-region title="Guild server time, Europe/Paris">{fmtTime.format(now * 1000)} <span data-tauri-drag-region>server time</span></time>
        {!guide && (
          <div className="titlebar-account">
            {signedIn ? (
              <>
                <span className="titlebar-member">{settings.memberName ?? "Signed in"}</span>
                <button className="titlebar-button" onClick={() => titleSignOut().catch(e => setProblem(message(e)))}>
                  Sign out
                </button>
              </>
            ) : signingIn ? (
              <button className="titlebar-button" onClick={() => api.cancelSignIn()}>
                Cancel sign-in
              </button>
            ) : (
              <button className="titlebar-button is-primary" disabled={signingOut.current || !settings.server} onClick={titleSignIn}>
                Sign in with Discord
              </button>
            )}
          </div>
        )}
        <WindowButtons />
      </header>

      {guide ? (
        <Welcome overview={overview} onUpdate={applyOverview} characters={characters} onDone={() => setGuide(false)} />
      ) : (
        <>
      <aside className="side">
        <Scene road={road} />
        <div className="side-pages"><nav className="rail-nav" aria-label="Pages">
          {PAGES.map(([id, name]) => (
            <button key={id} className={`rail-nav-item${page === id ? " is-current" : ""}`} aria-current={page === id ? "page" : undefined} onClick={() => setPage(id)}>
              <svg viewBox="0 0 20 20" aria-hidden="true">
                <path d={ICONS[id]} />
              </svg>
              <span>{name}</span>
              {id === "news" && news.items?.some(isUnread) && <span className="rail-dot" role="img" aria-label="Unread announcements" />}
              {id === "events" && planned > 0 && <span className="tab-count">{planned}</span>}
              {id === "characters" && characterMark && (
                <span className={`rail-dot${characterMark === "refused" ? " is-problem" : ""}`} role="img" aria-label={characterMark === "refused" ? "A request was not approved" : "Waiting for an officer"} title={characterMark === "refused" ? "A request was not approved" : "Waiting for an officer"} />
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
          launcherChecked={launcherChecked}
          updatingLauncher={updatingLauncher}
          updateProgress={launchProgress}
          onUpdateLauncher={installLauncher}
        />
        </div><div className="hearth">
          <Lantern mood={mood} label={label} hint={hint} onPress={play} disabled={!!busy || !!inGame || waiting} active={foreground && !inGame} />
          <div className={`status status-${road}`}>
            <p className="status-caption">Guild sync</p>
            <p role="status" className={`status-sync${lastSync?.error && !busy && signedIn ? " is-problem" : ""}`}>{syncLine}</p>
            {signedIn && lastSync?.error && !busy && <details className="status-details"><summary>Error details</summary><p tabIndex={0}>{lastSync.error}</p></details>}
            {signedIn && !!lastSync?.rejected.length && !busy && <details className="status-details"><summary>Updates needing attention</summary>{lastSync.rejected.map((reason, index) => <p key={index} tabIndex={0}>{reason}</p>)}</details>}
            {!busy && signedIn && <p className="status-note">{syncSummary(lastSync)}</p>}
            {overview.launchProblem && !busy && <p className="status-note is-problem" role="alert">{overview.launchProblem}</p>}
            {note && <p role="status" className="status-note">{note}</p>}
            {addonNote && !busy && <p role="status" className="status-note">{addonNote}</p>}
            {problem && <details className="status-details is-problem" open><summary>Action failed</summary><p role="alert" tabIndex={0}>{problem}</p></details>}
            {signedIn && (
              <p className="status-actions">
                <button className="link" disabled={!!busy} onClick={() => lastSync?.error || lastSync?.rejected.length ? recovery === "signin" ? signInAndSync() : recovery === "characters" ? setPage("characters") : act("sync", api.syncNow) : act("sync", api.syncNow)}>
                  {lastSync?.error || lastSync?.rejected.length ? recovery === "signin" ? "Sign in again" : recovery === "characters" ? "Check your characters" : "Try again" : "Sync now"}
                </button>
              </p>
            )}
            {!signedIn && <button className="link" disabled={signingOut.current || signingIn || !settings.server} onClick={titleSignIn}>{signingIn ? "Signing in…" : "Sign in with Discord"}</button>}
          </div>
        </div>
      </aside>

      <main className="hall">
        <div className="topbar">
          <div><h1>
            {PAGE_NAME[page]}
            {page === "events" && planned > 0 && <span className="tab-count">{planned}</span>}
          </h1>
          <p className="page-description">{PAGE_DESCRIPTION[page]}</p></div>
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
              <button className="btn" disabled={signingOut.current} onClick={() => setGuide(true)}>
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
              onRead={setSelectedEvent}
              onNews={openNews}
              isUnread={isUnread}
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
              onRead={setSelectedEvent}
            />
          )}
          {page === "characters" && <Characters characters={characters} signedIn={signedIn} problem={charactersProblem} onRetry={() => guild.refresh(true)} />}
          {page === "news" && <NewsReader items={news.items} signedIn={signedIn} problem={news.problem} selected={newsId} onOpen={setNewsId} isUnread={isUnread} onViewed={markRead} />}
          {page === "settings" && (
            <Settings
              overview={overview}
              onUpdate={applyOverview}
              launcherUpdate={launcherUpdate}
              onLauncherUpdate={launcherResult}
              onSignOut={titleSignOut}
              updateProgress={launchProgress}
            />
          )}
        </div>
      </main>
      {selectedEvent && <EventDetails event={selectedEvent} onClose={() => setSelectedEvent(null)} />}
        </>
      )}
    </div>
  );
}
