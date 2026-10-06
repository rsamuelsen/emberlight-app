mod game;
mod store;

use emberlight_sync::{api, auth, records::Notice, wow};
use game::{AddonStatus, WowStatus};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use store::{AddonCheck, Saved, Settings, SyncReport};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_updater::UpdaterExt;

struct AppState {
    path: PathBuf,
    saved: Mutex<Saved>,
    watching: AtomicBool,
    /// When Play was last pressed, until the game is seen running.
    launched: Mutex<Option<Instant>>,
    signing_in: AtomicBool,
    cancel_sign_in: AtomicBool,
    updating_addon: AtomicBool,
    /// Held while a sync runs.
    syncing: Mutex<()>,
    /// A launcher update found by `launcher_update`, waiting for the member to install it.
    launcher_update: Mutex<Option<tauri_plugin_updater::Update>>,
}

impl AppState {
    fn settings(&self) -> Settings {
        self.saved.lock().expect("state lock").settings.clone()
    }

    fn update(&self, f: impl FnOnce(&mut Saved)) -> Result<(), String> {
        let mut saved = self.saved.lock().expect("state lock");
        f(&mut saved);
        store::save(&self.path, &saved)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Overview {
    settings: Settings,
    signed_in: bool,
    wow: WowStatus,
    addon: AddonStatus,
    last_addon_check: Option<AddonCheck>,
    notices: Vec<Notice>,
    archive_written: Option<i64>,
    last_sync: Option<SyncReport>,
    watching: bool,
    launcher_version: String,
}

fn overview_now(app: &AppHandle) -> Overview {
    let state = app.state::<AppState>();
    let settings = state.settings();
    let (notices, archive_written) = game::installed_notices(&settings);
    let saved = state.saved.lock().expect("state lock").clone();
    Overview {
        wow: game::status(&settings),
        addon: game::addon_status(&settings),
        last_addon_check: saved.last_addon_check,
        signed_in: store::token().is_some(),
        notices,
        archive_written,
        last_sync: saved.last_sync,
        watching: state.watching.load(Ordering::SeqCst),
        launcher_version: app.package_info().version.to_string(),
        settings,
    }
}

/// Run blocking work (file scans, network, process list) off the UI thread.
async fn blocking<T: Send + 'static>(app: AppHandle, f: impl FnOnce(&AppHandle) -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(move || f(&app)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn overview(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| Ok(overview_now(app))).await
}

#[tauri::command]
async fn save_settings(app: AppHandle, wow_root: Option<String>, flavor: String, server: String) -> Result<Overview, String> {
    blocking(app, move |app| {
        let wow_root = wow_root.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty());
        if let Some(root) = &wow_root
            && !PathBuf::from(root).is_dir()
        {
            return Err("That World of Warcraft folder does not exist.".into());
        }
        if !emberlight_sync::paths::valid_flavor(&flavor) {
            return Err("Choose a game version.".into());
        }
        let server = server.trim().trim_end_matches('/').to_owned();
        if !server.is_empty() {
            api::server_url(&server).map_err(|e| e.to_string())?;
        }
        let state = app.state::<AppState>();
        state.update(|s| {
            if s.settings.server != server {
                s.settings.member_name = None;
                s.settings.discord_id = None;
            }
            // Choosing another game version is the member's choice from then on.
            if s.settings.flavor != flavor {
                s.settings.flavor_chosen = true;
            }
            s.settings.wow_root = wow_root;
            s.settings.flavor = flavor;
            s.settings.server = server;
            game::prefer_forever(&mut s.settings);
        })?;
        Ok(overview_now(app))
    })
    .await
}

#[tauri::command]
async fn sign_in(app: AppHandle, token: String) -> Result<Overview, String> {
    blocking(app, move |app| {
        let state = app.state::<AppState>();
        let settings = state.settings();
        if settings.server.is_empty() {
            return Err("Add the server address first.".into());
        }
        let token = token.trim().to_owned();
        let me = api::Client::new(&settings.server, &token).and_then(|c| c.me()).map_err(|e| e.to_string())?;
        store::set_token(&token)?;
        state.update(|s| {
            s.settings.member_name = Some(me.name);
            s.settings.discord_id = me.discord_id;
        })?;
        Ok(overview_now(app))
    })
    .await
}

/// Sign in through Discord in the system browser. The server checks guild membership; this app
/// only ever sees a one-time grant, which it redeems with its PKCE verifier.
#[tauri::command]
async fn sign_in_discord(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| {
        let state = app.state::<AppState>();
        let settings = state.settings();
        if settings.server.is_empty() {
            return Err("Add the server address first.".into());
        }
        if state.signing_in.swap(true, Ordering::SeqCst) {
            return Err("A sign-in is already waiting in your browser.".into());
        }
        state.cancel_sign_in.store(false, Ordering::SeqCst);
        let result = (|| -> Result<(), String> {
            let base = api::server_url(&settings.server).map_err(|e| e.to_string())?;
            let pkce = auth::Pkce::new();
            let app_state = auth::random_token();
            let loopback = auth::Loopback::bind().map_err(|e| format!("Could not start sign-in ({e})."))?;
            let url = auth::start_url(&base, loopback.port(), &app_state, &pkce.challenge);
            app.opener().open_url(url, None::<&str>).map_err(|e| format!("Could not open your browser ({e})."))?;
            let code = loopback.wait(&app_state, Duration::from_secs(300), &state.cancel_sign_in).map_err(|e| e.to_string())?;
            let (token, name) = api::exchange_grant(&settings.server, &code, &pkce.verifier).map_err(|e| e.to_string())?;
            store::set_token(&token)?;
            // The Discord id comes from /v1/me; the sign-in still counts if that read fails.
            let discord_id = api::Client::new(&settings.server, &token).and_then(|c| c.me()).ok().and_then(|me| me.discord_id);
            state.update(|s| {
                s.settings.member_name = Some(name);
                s.settings.discord_id = discord_id;
            })?;
            Ok(())
        })();
        state.signing_in.store(false, Ordering::SeqCst);
        result?;
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.set_focus();
        }
        Ok(overview_now(app))
    })
    .await
}

#[tauri::command]
fn cancel_sign_in(app: AppHandle) {
    app.state::<AppState>().cancel_sign_in.store(true, Ordering::SeqCst);
}

#[tauri::command]
async fn sign_out(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| {
        // End the session on the server first, so the token is useless even if the keychain keeps
        // it. Offline, signing out here still goes ahead; the session then ends when it expires.
        let settings = app.state::<AppState>().settings();
        let revoked = match store::token() {
            Some(token) => api::Client::new(&settings.server, &token).and_then(|c| c.logout()).is_ok(),
            None => true,
        };
        let cleared = store::clear_token();
        app.state::<AppState>().update(|s| {
            s.settings.member_name = None;
            s.settings.discord_id = None;
        })?;
        match (cleared, revoked) {
            (Err(e), true) => Err(format!("Signed out, and the server ended the session. {e} Remove \"{}\" from the system's credential manager.", store::KEYCHAIN_SERVICE)),
            (Err(e), false) => Err(format!(
                "Signed out on this computer only: the server could not be reached, and {} Sign in and out again when you are online, or remove \"{}\" from the system's credential manager.",
                e.to_lowercase(),
                store::KEYCHAIN_SERVICE
            )),
            (Ok(()), _) => Ok(overview_now(app)),
        }
    })
    .await
}

/// Read the member's name and Discord id again (a nickname may have changed since sign-in).
#[tauri::command]
async fn refresh_account(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| {
        let me = signed_in_client(app)?.me().map_err(|e| e.to_string())?;
        app.state::<AppState>().update(|s| {
            s.settings.member_name = Some(me.name);
            s.settings.discord_id = me.discord_id;
        })?;
        Ok(overview_now(app))
    })
    .await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Found {
    first_name: String,
    surname: Option<String>,
    name: String,
    realm: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CharactersView {
    realm: String,
    realms: Vec<String>,
    mine: Vec<api::Claim>,
    /// Characters seen on this computer on the guild's realm that are not linked or requested yet.
    found: Vec<Found>,
}

fn signed_in_client(app: &AppHandle) -> Result<api::Client, String> {
    let settings = app.state::<AppState>().settings();
    let token = store::token().ok_or("Sign in first.")?;
    api::Client::new(&settings.server, &token).map_err(|e| e.to_string())
}

fn realm_key(realm: &str) -> String {
    realm.chars().filter(|c| !c.is_whitespace() && *c != '-').collect::<String>().to_lowercase()
}

fn characters_view(app: &AppHandle) -> Result<CharactersView, String> {
    let client = signed_in_client(app)?;
    let mine = client.characters().map_err(|e| e.to_string())?;
    let realms = if mine.realms.is_empty() { vec![mine.realm.clone()] } else { mine.realms.clone() };
    let known: Vec<String> = mine.characters.iter().filter(|c| c.status != "refused").map(|c| c.name.to_lowercase()).collect();
    let found = game::local_characters(&app.state::<AppState>().settings())
        .into_iter()
        .filter_map(|full| {
            let (name, realm) = full.rsplit_once('-')?;
            if !realms.iter().any(|r| realm_key(r) == realm_key(realm)) {
                return None;
            }
            let mut parts = name.splitn(2, char::is_whitespace);
            let first_name = parts.next()?.to_owned();
            let surname = parts.next().map(|s| s.trim().to_owned()).filter(|s| !s.is_empty());
            let name = name.trim().to_owned();
            (!known.contains(&name.to_lowercase())).then_some(Found { first_name, surname, name, realm: realm.to_owned() })
        })
        .collect();
    Ok(CharactersView { realm: mine.realm, realms, mine: mine.characters, found })
}

/// Read only: characters are linked and removed on the guild website (owner's decision, 4 October 2026).
#[tauri::command]
async fn characters(app: AppHandle) -> Result<CharactersView, String> {
    blocking(app, characters_view).await
}

#[tauri::command]
async fn announcements(app: AppHandle) -> Result<Vec<api::Announcement>, String> {
    blocking(app, |app| signed_in_client(app)?.announcements().map_err(|e| e.to_string())).await
}

/// The guild's official events (`official`) or members' adventures (`member`) straight from the
/// server, so a member sees them whichever game folder or guild their characters are in, and
/// before they are near enough to reach the game.
#[tauri::command]
async fn guild_events(app: AppHandle, kind: String) -> Result<Vec<api::GuildEvent>, String> {
    blocking(app, move |app| signed_in_client(app)?.events(&kind).map_err(|e| e.to_string())).await
}

/// A Windows notification: a new guild event, or one the member joins starting soon. Sent from
/// Rust, so the page needs no notification permission of its own.
#[tauri::command]
fn notify(app: AppHandle, title: String, body: String) -> Result<(), String> {
    use tauri_plugin_notification::NotificationExt;
    app.notification().builder().title(title).body(body).show().map_err(|e| e.to_string())
}

/// Links from announcements and events open in the member's own browser, never inside the launcher.
#[tauri::command]
fn open_link(app: AppHandle, url: String) -> Result<(), String> {
    let parsed = tauri::Url::parse(&url).map_err(|_| "That link is not valid.".to_string())?;
    if parsed.scheme() != "https" || parsed.host_str().is_none() {
        return Err("Only https links can be opened.".into());
    }
    app.opener().open_url(parsed.as_str(), None::<&str>).map_err(|e| format!("Could not open your browser ({e})."))
}

fn record_sync(app: &AppHandle) -> Option<SyncReport> {
    let state = app.state::<AppState>();
    // One sync at a time: Sync now, Play and the game watcher can ask at once; a second waits.
    let _one = state.syncing.lock().unwrap_or_else(|e| e.into_inner());
    let token = store::token()?;
    let report = game::sync(&state.settings(), &token);
    let _ = state.update(|s| s.last_sync = Some(report.clone()));
    Some(report)
}

#[tauri::command]
async fn sync_now(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| {
        record_sync(app).ok_or("Sign in under Settings first.")?;
        Ok(overview_now(app))
    })
    .await
}

/// Run one addon change at a time and remember how it went.
fn addon_change(app: &AppHandle, change: fn(&Settings) -> Result<game::AddonOutcome, String>) -> Result<Overview, String> {
    let state = app.state::<AppState>();
    if state.updating_addon.swap(true, Ordering::SeqCst) {
        return Err("The addon is already being updated.".into());
    }
    let result = change(&state.settings());
    state.updating_addon.store(false, Ordering::SeqCst);
    let previous_latest = state.saved.lock().expect("state lock").last_addon_check.as_ref().and_then(|c| c.latest.clone());
    let check = match &result {
        Ok((kind, message, latest)) => AddonCheck { at: game::now(), message: message.clone(), error: false, kind: (*kind).into(), latest: latest.clone().or(previous_latest) },
        Err(e) => AddonCheck { at: game::now(), message: e.clone(), error: true, kind: "failed".into(), latest: previous_latest },
    };
    state.update(|s| s.last_addon_check = Some(check))?;
    result?;
    Ok(overview_now(app))
}

/// Install the Emberlight addon, or update it to the guild's newest signed release.
#[tauri::command]
async fn update_addon(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| addon_change(app, game::update_addon)).await
}

/// Only look for a newer addon; nothing is installed.
#[tauri::command]
async fn check_addon(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| addon_change(app, game::check_addon)).await
}

/// Whether the app installs a newer addon by itself when it opens.
#[tauri::command]
async fn set_auto_update_addon(app: AppHandle, on: bool) -> Result<Overview, String> {
    blocking(app, move |app| {
        app.state::<AppState>().update(|s| s.settings.auto_update_addon = on)?;
        Ok(overview_now(app))
    })
    .await
}

/// Whether closing the window keeps the app in the tray.
#[tauri::command]
async fn set_keep_in_tray(app: AppHandle, on: bool) -> Result<Overview, String> {
    blocking(app, move |app| {
        app.state::<AppState>().update(|s| s.settings.keep_in_tray = on)?;
        Ok(overview_now(app))
    })
    .await
}

/// Put back the version kept by the last update.
#[tauri::command]
async fn restore_addon(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| addon_change(app, game::restore_addon)).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LauncherUpdate {
    version: String,
    notes: Option<String>,
}

/// Ask the guild's server whether a newer launcher is published. Its installer is signed with the
/// launcher update key; the updater checks that signature against the key built into this app.
#[tauri::command]
async fn launcher_update(app: AppHandle) -> Result<Option<LauncherUpdate>, String> {
    let found = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|_| "Could not check for a new version of Emberlight Companion.".to_string())?;
    let info = found.as_ref().map(|u| LauncherUpdate { version: u.version.clone(), notes: u.body.clone().filter(|b| !b.trim().is_empty()) });
    *app.state::<AppState>().launcher_update.lock().expect("update lock") = found;
    Ok(info)
}

/// Download and install the update found by `launcher_update`, then restart into it.
#[tauri::command]
async fn install_launcher_update(app: AppHandle) -> Result<(), String> {
    let state = app.state::<AppState>();
    if state.watching.load(Ordering::SeqCst) {
        return Err("Update Emberlight Companion after you close World of Warcraft.".into());
    }
    let update = state.launcher_update.lock().expect("update lock").take().ok_or("There is no launcher update waiting.")?;
    update
        .download_and_install(|_, _| {}, || {})
        .await
        .map_err(|e| format!("The update could not be installed ({e})."))?;
    app.restart();
}

#[tauri::command]
async fn play(app: AppHandle) -> Result<Overview, String> {
    blocking(app, |app| {
        let settings = app.state::<AppState>().settings();
        let root = game::root(&settings)?;
        if !wow::running_clients(Some(&root)).is_empty() {
            return Err("World of Warcraft is already running.".into());
        }
        if app.state::<AppState>().updating_addon.load(Ordering::SeqCst) {
            return Err("Wait a moment: the addon is being updated.".into());
        }
        record_sync(app);
        game::launch(&settings)?;
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.hide();
        }
        let state = app.state::<AppState>();
        *state.launched.lock().expect("launch lock") = Some(Instant::now());
        state.watching.store(true, Ordering::SeqCst);
        Ok(overview_now(app))
    })
    .await
}

/// Close from the title bar: stay in the tray while a game session is being watched, or always when
/// the member keeps the app in the tray (the default). Quit is in the tray menu.
#[tauri::command]
fn close_window(app: AppHandle) {
    let state = app.state::<AppState>();
    if state.watching.load(Ordering::SeqCst) || state.settings().keep_in_tray {
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.hide();
        }
    } else {
        app.exit(0);
    }
}

/// Watch for the game for as long as the app is open, however it was started (Play here, or
/// Battle.net directly). When it starts or closes the window is told, and when it closes what it
/// saved is synced. After Play, the game gets ten minutes to appear.
fn monitor_game(app: AppHandle) {
    std::thread::spawn(move || {
        let mut clients = wow::Clients::new();
        let mut seen = false;
        loop {
            std::thread::sleep(Duration::from_secs(3));
            let state = app.state::<AppState>();
            let running = !clients.running(game::root(&state.settings()).ok().as_deref()).is_empty();
            if running == seen {
                let mut launched = state.launched.lock().expect("launch lock");
                let waiting = launched.is_some_and(|at| at.elapsed() <= Duration::from_secs(600));
                if !running && !waiting && state.watching.swap(false, Ordering::SeqCst) {
                    *launched = None;
                    let _ = app.emit("overview-changed", ());
                }
                continue;
            }
            seen = running;
            if running {
                *state.launched.lock().expect("launch lock") = None;
                state.watching.store(true, Ordering::SeqCst);
            } else {
                // WoW writes SavedVariables before it exits; give the file system a moment.
                std::thread::sleep(Duration::from_secs(2));
                record_sync(&app);
                state.watching.store(false, Ordering::SeqCst);
            }
            let _ = app.emit("overview-changed", ());
        }
    });
}

fn show_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        let _ = app.emit("overview-changed", ());
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // Must be registered first: a second launch just brings the open window forward.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_window(app)))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let path = app.path().app_config_dir()?.join("settings.json");
            let mut saved = store::load(&path);
            game::prefer_forever(&mut saved.settings);
            // Released builds always talk to the guild's own server; only a development build can be
            // pointed at another one (Settings, Advanced, shown in development only).
            if !cfg!(debug_assertions) {
                saved.settings.server = store::DEFAULT_SERVER.into();
            }
            app.manage(AppState {
                path,
                saved: Mutex::new(saved),
                watching: AtomicBool::new(false),
                launched: Mutex::new(None),
                signing_in: AtomicBool::new(false),
                cancel_sign_in: AtomicBool::new(false),
                updating_addon: AtomicBool::new(false),
                syncing: Mutex::new(()),
                launcher_update: Mutex::new(None),
            });

            let open = MenuItem::with_id(app, "open", "Open Emberlight", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            let mut tray = TrayIconBuilder::with_id("main")
                .tooltip("Emberlight")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_window(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            monitor_game(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            overview,
            save_settings,
            sign_in,
            sign_in_discord,
            cancel_sign_in,
            sign_out,
            refresh_account,
            characters,
            announcements,
            guild_events,
            notify,
            open_link,
            sync_now,
            update_addon,
            check_addon,
            set_auto_update_addon,
            set_keep_in_tray,
            restore_addon,
            launcher_update,
            install_launcher_update,
            play,
            close_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running Emberlight Companion");
}
