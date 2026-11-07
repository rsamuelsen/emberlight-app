//! Finding World of Warcraft, syncing and starting its client.
//!
//! Start the game through Battle.net, which signs the member in; start the client directly only
//! when Battle.net cannot (on macOS the client is still started directly first). Credentials stay
//! with the game and Battle.net.

use crate::store::{Settings, SyncReport};
use emberlight_sync::{api, datafile, flow, lua, paths, records, update, wow};
use serde::Serialize;
use std::path::{Path, PathBuf};
#[cfg(any(windows, target_os = "macos"))]
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WowStatus {
    pub root: Option<String>,
    pub problem: Option<String>,
    pub flavors: Vec<String>,
    /// The game folders that are WoW: Forever (the released game or its beta), whatever their name.
    pub forever: Vec<String>,
    pub emberlight: Option<String>,
    pub version: Option<String>,
    pub accounts: Vec<String>,
    pub game_running: bool,
    /// The game programs still running, so the member can see what to close.
    pub running: Vec<String>,
}

pub fn root(settings: &Settings) -> Result<PathBuf, String> {
    paths::find_root(settings.wow_root.as_deref().map(Path::new)).map_err(|e| e.to_string())
}

/// WoW: Forever's game folder since launch (4 November 2026), seen on a real install.
pub const FOREVER: &str = "_forever_";
/// The WoW: Forever beta's game folder (WowB.exe), where the guild played in October 2026.
pub const FOREVER_BETA: &str = "_classic_beta_";

/// The installed WoW: Forever folder to use: the released game (`_forever_`, or any other folder
/// Battle.net says is Forever and not a test client), else the beta.
pub fn forever_folder(root: &Path) -> Option<String> {
    let found = paths::flavors(root);
    let live = found.iter().find(|f| f.as_str() == FOREVER).or_else(|| {
        found.iter().find(|f| {
            let dir = root.join(f.as_str());
            f.as_str() != FOREVER_BETA && paths::is_forever(&dir) && !paths::is_test_client(&dir)
        })
    });
    live.or_else(|| found.iter().find(|f| f.as_str() == FOREVER_BETA)).cloned()
}

/// The Companion follows WoW: Forever. Keep an explicitly chosen Forever client, but migrate
/// old Retail/Classic choices and missing clients to the released game, else its beta.
/// If Forever is not installed, target its missing folder rather than updating another game.
pub fn prefer_forever(settings: &mut Settings) {
    let root = root(settings).ok();
    if settings.flavor_chosen
        && let Some(dir) = root.as_ref().and_then(|r| paths::flavor_dir(r, &settings.flavor).ok())
        && (settings.flavor == FOREVER_BETA || paths::is_forever(&dir))
    {
        return;
    }
    settings.flavor = root.as_deref().and_then(forever_folder).unwrap_or_else(|| FOREVER.into());
}

pub fn status(settings: &Settings) -> WowStatus {
    let root = root(settings);
    let running = wow::running_clients(root.as_deref().ok());
    let game_running = !running.is_empty();
    let root = match root {
        Ok(r) => r,
        Err(problem) => {
            return WowStatus { root: None, problem: Some(problem), flavors: vec![], forever: vec![], emberlight: None, version: None, accounts: vec![], game_running, running };
        }
    };
    let flavors = paths::flavors(&root);
    let forever = flavors.iter().filter(|f| f.as_str() == FOREVER_BETA || paths::is_forever(&root.join(f.as_str()))).cloned().collect();
    let (emberlight, accounts, problem) = match paths::flavor_dir(&root, &settings.flavor) {
        Ok(dir) => (
            datafile::read_interface(&paths::addons_dir(&dir)).ok(),
            paths::saved_variables(&dir).into_iter().map(|a| a.account).collect(),
            None,
        ),
        Err(e) => (None, vec![], Some(e.to_string())),
    };
    let version = paths::game_product(&root.join(&settings.flavor)).and_then(|product| paths::game_version(&root, &product));
    WowStatus { root: Some(root.display().to_string()), problem, flavors, forever, emberlight, version, accounts, game_running, running }
}

/// "Name-Realm" of every character played in this game folder: those the game has made a folder
/// for, and those found in Emberlight's own saved drafts and notices.
pub fn local_characters(settings: &Settings) -> Vec<String> {
    let Ok(root) = root(settings) else { return vec![] };
    let Ok(dir) = paths::flavor_dir(&root, &settings.flavor) else { return vec![] };
    let mut all: Vec<String> = paths::saved_variables(&dir)
        .into_iter()
        .filter_map(|a| std::fs::read(a.path).ok())
        .filter_map(|b| lua::parse(&b).ok())
        .flat_map(|g| records::local_characters(&g))
        .chain(paths::character_folders(&dir))
        .collect();
    all.sort();
    all.dedup();
    all
}

/// Notices currently installed in Emberlight_Data, and when they were written.
pub fn installed_notices(settings: &Settings) -> (Vec<records::Notice>, Option<i64>) {
    let Ok(root) = root(settings) else { return (vec![], None) };
    let Ok(dir) = paths::flavor_dir(&root, &settings.flavor) else { return (vec![], None) };
    let file = paths::addons_dir(&dir).join(datafile::ADDON_DIR).join("Data.lua");
    match std::fs::read(file).ok().and_then(|b| datafile::read_data(&b).ok()) {
        Some(archive) => (archive.notices, Some(archive.generated)),
        None => (vec![], None),
    }
}

/// Upload this member's notices, then download the guild's into Emberlight_Data unless the game
/// is running. Never fails outright: problems are reported in the result.
pub fn sync(settings: &Settings, token: &str) -> SyncReport {
    let mut report = SyncReport { at: now(), ..Default::default() };
    if let Err(e) = sync_inner(settings, token, &mut report) {
        report.error = Some(e);
    }
    report
}

fn sync_inner(settings: &Settings, token: &str, report: &mut SyncReport) -> Result<(), String> {
    if settings.server.trim().is_empty() {
        return Err("Add the server address in Settings.".into());
    }
    let client = api::Client::new(&settings.server, token).map_err(|e| e.to_string())?;
    let root = root(settings)?;
    let dir = paths::flavor_dir(&root, &settings.flavor).map_err(|e| e.to_string())?;

    let files: Vec<_> = paths::saved_variables(&dir).into_iter().map(|a| a.path).collect();
    let pushed = flow::push(&client, &files, now()).map_err(|e| e.to_string())?;
    report.uploaded = pushed.notices + pushed.replies + pushed.removals;
    // Professions the website took count as updates too (addon 0.8.13).
    report.stored = pushed.stored + pushed.professions;
    report.rejected = pushed.problems;
    // Own events in a guild the website does not sync are never uploaded: say so, or the sync
    // looks fine while nothing arrives (the beta once renumbered the guild's region).
    let unsynced = (!pushed.unsynced.is_empty()).then(|| {
        format!("Your events were not sent: the website does not sync this guild yet ({}). Please tell an officer.", pushed.unsynced.join(", "))
    });
    report.note = unsynced.clone();

    if !wow::running_clients(Some(&root)).is_empty() {
        let running = "World of Warcraft is running. New notices will be added after it closes.";
        report.note = Some(unsynced.map_or(running.to_owned(), |u| format!("{u} {running}")));
        return Ok(());
    }
    // The game can be started from Battle.net while this downloads: check again before writing.
    let still_closed = || {
        if !wow::running_clients(Some(&root)).is_empty() {
            anyhow::bail!("World of Warcraft started during the download. New notices will be added after it closes.");
        }
        Ok(())
    };
    let written = flow::pull(&client, &paths::addons_dir(&dir), still_closed).map_err(|e| e.to_string())?;
    report.downloaded = Some(written.written);
    // Officers only: the roster check could not be updated (the notices were).
    if let Some(problem) = written.roster_problem {
        let line = format!("The roster check was not updated: {problem}.");
        report.note = Some(match report.note.take() {
            Some(note) => format!("{note} {line}"),
            None => line,
        });
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AddonStatus {
    /// Version of the Emberlight addon in this game version, if installed.
    pub installed: Option<String>,
    /// Version kept by the last update, which can be put back.
    pub previous: Option<String>,
}

fn addons(settings: &Settings) -> Result<(PathBuf, PathBuf), String> {
    let root = root(settings)?;
    let dir = paths::flavor_dir(&root, &settings.flavor).map_err(|e| e.to_string())?;
    Ok((paths::addons_dir(&dir), root))
}

pub fn addon_status(settings: &Settings) -> AddonStatus {
    match addons(settings) {
        Ok((dir, _)) => AddonStatus { installed: update::installed_version(&dir), previous: update::previous_version(&dir) },
        Err(_) => AddonStatus { installed: None, previous: None },
    }
}

fn game_closed(root: &Path) -> Result<(), String> {
    if wow::running_clients(Some(root)).is_empty() {
        Ok(())
    } else {
        Err("Close World of Warcraft first. The addon can only be changed while the game is closed.".into())
    }
}

/// What an addon check or change decided: its kind, a line for the member, and the guild's newest
/// published version when the server was reached.
pub type AddonOutcome = (&'static str, String, Option<String>);

/// Install Emberlight, or update it if the guild has published a newer version.
pub fn update_addon(settings: &Settings) -> Result<AddonOutcome, String> {
    let (dir, root) = addons(settings)?;
    game_closed(&root)?;
    let tags = paths::folder_tags(&root.join(&settings.flavor));
    let outcome = update::check_and_install(&settings.server, &dir, Some(&tags), update::RELEASE_PUBLIC_KEY, env!("CARGO_PKG_VERSION"))
        .map_err(|e| sentence(&e.to_string()))?;
    Ok(match outcome {
        update::Outcome::UpToDate(v) => ("current", format!("Emberlight {v} is up to date."), Some(v)),
        update::Outcome::NotPublished => ("unpublished", "The guild has not published an addon version yet.".into(), None),
        update::Outcome::Installed(i) => {
            let message = match i.previous {
                Some(p) => format!("Emberlight updated from {p} to {}. It takes effect the next time you log in.", i.version),
                None => format!("Emberlight {} installed. It takes effect the next time you log in.", i.version),
            };
            ("installed", message, Some(i.version))
        }
    })
}

/// Only look: whether the guild has published a newer addon than the one installed. Allowed while
/// the game runs, since nothing is changed.
pub fn check_addon(settings: &Settings) -> Result<AddonOutcome, String> {
    let (dir, root) = addons(settings)?;
    let tags = paths::folder_tags(&root.join(&settings.flavor));
    let latest = update::latest_version(&settings.server, Some(&tags), update::RELEASE_PUBLIC_KEY, env!("CARGO_PKG_VERSION"))
        .map_err(|e| sentence(&e.to_string()))?;
    let installed = update::installed_version(&dir);
    Ok(match (latest, installed) {
        (None, _) => ("unpublished", "The guild has not published an addon version yet.".into(), None),
        (Some(l), Some(i)) if !update::is_newer(&l, &i) => ("current", format!("Emberlight {i} is up to date."), Some(l)),
        (Some(l), _) => ("available", format!("Emberlight {l} is ready to install."), Some(l)),
    })
}

pub fn restore_addon(settings: &Settings) -> Result<AddonOutcome, String> {
    let (dir, root) = addons(settings)?;
    game_closed(&root)?;
    let version = update::restore_previous(&dir).map_err(|e| sentence(&e.to_string()))?;
    Ok(("restored", format!("Emberlight {version} is back in place."), None))
}

/// Library errors are lower-case fragments; show them as a sentence.
fn sentence(s: &str) -> String {
    let mut chars = s.chars();
    let mut out: String = chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default();
    if !out.ends_with('.') {
        out.push('.');
    }
    out
}

/// Only known game-client filenames are executable candidates. Never start helpers or tools.
#[cfg(any(not(target_os = "macos"), test))]
fn client_priority(name: &str) -> Option<usize> {
    ["wow.exe", "wowforever.exe", "wowf.exe", "wowclassic.exe", "wowb.exe", "wowclassicb.exe", "wowt.exe", "wowclassict.exe"]
        .iter().position(|candidate| name.eq_ignore_ascii_case(candidate))
}

#[cfg(any(not(target_os = "macos"), test))]
fn client_executable(dir: &Path) -> Option<PathBuf> {
    let root = dir.canonicalize().ok()?;
    let mut clients: Vec<_> = std::fs::read_dir(dir).ok()?.filter_map(Result::ok).filter_map(|entry| {
        let priority = client_priority(entry.file_name().to_str()?)?;
        let path = entry.path().canonicalize().ok()?;
        (path.is_file() && path.parent() == Some(root.as_path())).then_some((priority, path))
    }).collect();
    clients.sort_by_key(|(priority, _)| *priority);
    clients.into_iter().next().map(|(_, path)| path)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaunchMethod {
    Direct,
    BattleNet,
    /// Battle.net was closed. It opens on the game's page but ignores the start command while it
    /// loads, so the command is sent again (`tries` so far) until the game appears, Battle.net's log
    /// shows it started the game, or the tries run out. The member can always press Play there.
    BattleNetOpening { since: SystemTime, tries: u8 },
}

/// How long to wait between start commands while Battle.net opens, and how many to send again.
pub const BATTLE_NET_RETRY: Duration = Duration::from_secs(12);
const BATTLE_NET_TRIES: u8 = 3;

pub fn launch(settings: &Settings) -> Result<LaunchMethod, String> {
    let dir = paths::flavor_dir(&root(settings)?, &settings.flavor).map_err(|e| e.to_string())?;
    launch_from(&dir)
}

/// Battle.net's launch code for a product named in `.flavor.info`. The codes are case-sensitive and
/// not always the product: when Play is pressed Battle.net's log names Forever "WoWF", and
/// "launch wowf" does nothing (tested on Windows, 5 November 2026).
fn launch_code(product: &str) -> &str {
    match product {
        "wow" => "WoW",
        "wowf" => "WoWF",
        other => other,
    }
}

fn battle_net_argument(dir: &Path) -> Result<String, String> {
    let product = paths::game_product(dir).ok_or("The Battle.net product could not be identified. Start the game from Battle.net.")?;
    Ok(format!("--exec=\"launch {}\"", launch_code(&product)))
}

pub fn fallback_launch(settings: &Settings) -> Result<LaunchMethod, String> {
    let dir = paths::flavor_dir(&root(settings)?, &settings.flavor).map_err(|e| e.to_string())?;
    launch_battle_net(&battle_net_argument(&dir)?)?;
    Ok(LaunchMethod::BattleNet)
}

/// While Battle.net opens: send the start command again, unless Battle.net has already started the
/// game. Returns what to wait for next.
pub fn nudge_battle_net(settings: &Settings, method: LaunchMethod) -> LaunchMethod {
    let LaunchMethod::BattleNetOpening { since, tries } = method else { return method };
    let dir = root(settings).ok().and_then(|r| paths::flavor_dir(&r, &settings.flavor).ok());
    let product = dir.as_deref().and_then(paths::game_product);
    next_nudge(since, tries, product.is_some_and(|p| battle_net_started(since, &p)), || {
        dir.as_deref().ok_or_else(|| "no game folder".to_owned()).and_then(battle_net_argument).and_then(|a| launch_battle_net(&a))
    })
}

fn next_nudge(since: SystemTime, tries: u8, started: bool, send: impl FnOnce() -> Result<(), String>) -> LaunchMethod {
    if started || send().is_err() || tries + 1 >= BATTLE_NET_TRIES { return LaunchMethod::BattleNet; }
    LaunchMethod::BattleNetOpening { since, tries: tries + 1 }
}

/// Whether Battle.net's own log, written since `since`, says it is starting `product` (the line
/// "LaunchBinary: uid=wowf ..." it writes when Play is pressed), so it is not asked twice.
#[cfg(windows)]
fn battle_net_started(since: SystemTime, product: &str) -> bool {
    use std::io::{Read, Seek, SeekFrom};
    let Some(logs) = std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Battle.net").join("Logs")) else { return false };
    let Ok(entries) = std::fs::read_dir(logs) else { return false };
    let needle = format!("launchbinary: uid={}", product.to_ascii_lowercase());
    entries.filter_map(Result::ok).filter(|e| {
        let name = e.file_name().to_string_lossy().to_ascii_lowercase();
        name.starts_with("battle.net") && name.ends_with(".log")
            && e.metadata().and_then(|m| m.modified()).is_ok_and(|m| m >= since)
    }).any(|e| {
        let Ok(mut file) = std::fs::File::open(e.path()) else { return false };
        let length = file.metadata().map(|m| m.len()).unwrap_or(0);
        let _ = file.seek(SeekFrom::Start(length.saturating_sub(256 * 1024)));
        let mut tail = Vec::new();
        file.read_to_end(&mut tail).is_ok() && String::from_utf8_lossy(&tail).to_ascii_lowercase().contains(&needle)
    })
}

#[cfg(not(windows))]
fn battle_net_started(_since: SystemTime, _product: &str) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn finish_launch(direct: Result<(), String>, dir: &Path, fallback: impl FnOnce(&str) -> Result<(), String>) -> Result<LaunchMethod, String> {
    if direct.is_ok() { return Ok(LaunchMethod::Direct); }
    fallback(&battle_net_argument(dir)?).map(|_| LaunchMethod::BattleNet)
        .map_err(|error| format!("The game could not be started directly or through Battle.net. {error}"))
}

/// Battle.net first, because a game it starts is signed in; a client started directly asks the
/// member to log in. Battle.net that is already open starts the game at once; one that was closed
/// is nudged again by `nudge_battle_net`. The client is started directly only if Battle.net cannot.
#[cfg(any(not(target_os = "macos"), test))]
fn start_through_battle_net(
    argument: Result<String, String>,
    open: bool,
    since: SystemTime,
    battle_net: impl FnOnce(&str) -> Result<(), String>,
    direct: impl FnOnce() -> Result<(), String>,
) -> Result<LaunchMethod, String> {
    let through = argument.and_then(|a| battle_net(&a));
    match through {
        Ok(()) if open => Ok(LaunchMethod::BattleNet),
        Ok(()) => Ok(LaunchMethod::BattleNetOpening { since, tries: 0 }),
        Err(first) => direct().map(|_| LaunchMethod::Direct)
            .map_err(|error| format!("The game could not be started through Battle.net or directly. {first} {error}")),
    }
}

#[cfg(target_os = "macos")]
fn launch_from(dir: &Path) -> Result<LaunchMethod, String> {
    finish_launch(start_client(dir, dir), dir, launch_battle_net)
}

#[cfg(not(target_os = "macos"))]
fn launch_from(dir: &Path) -> Result<LaunchMethod, String> {
    start_through_battle_net(battle_net_argument(dir), wow::battle_net_running(), SystemTime::now(), launch_battle_net, || {
        client_executable(dir).ok_or_else(|| "The game client was not found.".to_owned()).and_then(|exe| start_client(&exe, dir))
    })
}

#[cfg(windows)]
fn start_client(exe: &Path, dir: &Path) -> Result<(), String> {
    Command::new(exe).current_dir(dir).spawn().map(|_| ()).map_err(|e| format!("Could not start the game ({e})."))
}

#[cfg(target_os = "macos")]
fn start_client(_exe: &Path, dir: &Path) -> Result<(), String> {
    let app = ["World of Warcraft.app", "World of Warcraft Classic.app"].iter().map(|n| dir.join(n)).find(|p| p.is_dir())
        .ok_or("The game app was not found.")?;
    Command::new("open").arg(app).status().map_err(|e| e.to_string())?
        .success().then_some(()).ok_or_else(|| "Could not start the game.".into())
}

#[cfg(not(any(windows, target_os = "macos")))]
fn start_client(_exe: &Path, _dir: &Path) -> Result<(), String> {
    Err("Launching is only available on Windows and macOS.".into())
}

#[cfg(windows)]
fn launch_battle_net(argument: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    let exe = paths::battle_net_exe().ok_or("Battle.net was not found. Start the game from Battle.net.")?;
    Command::new(exe)
        .raw_arg(argument)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Could not start Battle.net ({e})."))
}

#[cfg(target_os = "macos")]
fn launch_battle_net(argument: &str) -> Result<(), String> {
    Command::new("open")
        .args(["-a", "Battle.net", "--args", &argument.replace('"', "")])
        .status()
        .map_err(|e| format!("Could not start Battle.net ({e})."))
        .and_then(|s| if s.success() { Ok(()) } else { Err("Battle.net was not found. Start the game from Battle.net.".into()) })
}

#[cfg(not(any(windows, target_os = "macos")))]
fn launch_battle_net(_argument: &str) -> Result<(), String> {
    Err("Launching is only available on Windows and macOS.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_through_battle_net_and_directly_only_when_it_cannot() {
        let dir = std::env::temp_dir().join(format!("emberlight-fallback-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".flavor.info"), "Product Flavor!STRING:0\nwowf\n").unwrap();
        let since = SystemTime::now();
        let argument = || battle_net_argument(&dir);
        assert_eq!(argument(), Ok("--exec=\"launch WoWF\"".to_owned()));
        let no_direct = || -> Result<(), String> { panic!("the client must not start directly after Battle.net took it") };
        assert_eq!(start_through_battle_net(argument(), true, since, |a| { assert_eq!(a, "--exec=\"launch WoWF\""); Ok(()) }, no_direct), Ok(LaunchMethod::BattleNet));
        assert_eq!(start_through_battle_net(argument(), false, since, |_| Ok(()), no_direct), Ok(LaunchMethod::BattleNetOpening { since, tries: 0 }));
        assert_eq!(start_through_battle_net(argument(), true, since, |_| Err("no Battle.net".into()), || Ok(())), Ok(LaunchMethod::Direct));
        assert_eq!(start_through_battle_net(Err("unknown product".into()), true, since, |_| panic!("no code, no Battle.net"), || Ok(())), Ok(LaunchMethod::Direct));
        let both = start_through_battle_net(argument(), true, since, |_| Err("no Battle.net.".into()), || Err("no client.".into())).unwrap_err();
        assert!(both.contains("no Battle.net") && both.contains("no client"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn launch_codes_keep_battle_net_case() {
        assert_eq!(launch_code("wowf"), "WoWF");
        assert_eq!(launch_code("wow"), "WoW");
        assert_eq!(launch_code("wow_classic_beta"), "wow_classic_beta");
    }

    #[test]
    fn nudges_battle_net_until_it_starts_the_game_or_tries_run_out() {
        let since = SystemTime::now();
        let sent = std::cell::Cell::new(0);
        let send = || { sent.set(sent.get() + 1); Ok(()) };
        assert_eq!(next_nudge(since, 0, false, send), LaunchMethod::BattleNetOpening { since, tries: 1 });
        assert_eq!(next_nudge(since, 1, false, send), LaunchMethod::BattleNetOpening { since, tries: 2 });
        assert_eq!(next_nudge(since, 2, false, send), LaunchMethod::BattleNet);
        assert_eq!(sent.get(), 3);
        assert_eq!(next_nudge(since, 0, true, || panic!("Battle.net already started the game")), LaunchMethod::BattleNet);
        assert_eq!(next_nudge(since, 0, false, || Err("gone".into())), LaunchMethod::BattleNet);
    }

    #[test]
    fn finds_the_client_and_never_a_helper() {
        let dir = std::env::temp_dir().join(format!("emberlight-exe-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for name in ["Battle.net.exe", "BlizzardError.exe", "WowVoiceProxy.exe", "WowTools.exe"] {
            std::fs::write(dir.join(name), "").unwrap();
        }
        assert!(client_executable(&dir).is_none());
        std::fs::write(dir.join("WowForever.exe"), "").unwrap();
        assert_eq!(client_executable(&dir).unwrap().file_name().unwrap(), "WowForever.exe");
        std::fs::write(dir.join("Wow.exe"), "").unwrap();
        assert_eq!(client_executable(&dir).unwrap().file_name().unwrap(), "Wow.exe");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn forever_replaces_old_client_choices_and_keeps_forever_choices() {
        assert_eq!(Settings::default().flavor, FOREVER);
        let dir = std::env::temp_dir().join(format!("emberlight-flavor-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("_retail_")).unwrap();
        let mut legacy = Settings { wow_root: Some(dir.display().to_string()), flavor: "_retail_".into(), flavor_chosen: true, ..Settings::default() };
        prefer_forever(&mut legacy);
        assert_eq!(legacy.flavor, "_forever_", "Retail alone is never the fallback");
        std::fs::create_dir_all(dir.join("_classic_beta_")).unwrap();
        let mut settings = Settings { wow_root: Some(dir.display().to_string()), ..Settings::default() };
        prefer_forever(&mut settings);
        assert_eq!(settings.flavor, "_classic_beta_");
        // The released game wins over the beta, also for a member the beta was picked for.
        std::fs::create_dir_all(dir.join("_forever_")).unwrap();
        prefer_forever(&mut settings);
        assert_eq!(settings.flavor, "_forever_");
        let mut chosen = Settings { wow_root: Some(dir.display().to_string()), flavor: "_retail_".into(), flavor_chosen: true, ..Settings::default() };
        prefer_forever(&mut chosen);
        assert_eq!(chosen.flavor, "_forever_", "Migrate the old Retail test selection");
        let mut beta = Settings { wow_root: Some(dir.display().to_string()), flavor: "_classic_beta_".into(), flavor_chosen: true, ..Settings::default() };
        prefer_forever(&mut beta);
        assert_eq!(beta.flavor, "_classic_beta_", "An explicit Forever beta choice is kept");
        // A chosen beta that was uninstalled after launch moves to the released game.
        let mut gone = Settings { wow_root: Some(dir.display().to_string()), flavor: "_classic_beta_".into(), flavor_chosen: true, ..Settings::default() };
        std::fs::remove_dir_all(dir.join("_classic_beta_")).unwrap();
        prefer_forever(&mut gone);
        assert_eq!(gone.flavor, "_forever_");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
