//! Finding World of Warcraft, syncing and launching through Battle.net.
//!
//! The launcher never handles Blizzard credentials: it asks Battle.net to start the game, and
//! Battle.net signs the player in as usual.

use crate::store::{Settings, SyncReport};
use emberlight_sync::{api, datafile, flow, lua, paths, records, update, wow};
use serde::Serialize;
use std::path::{Path, PathBuf};
#[cfg(any(windows, target_os = "macos"))]
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WowStatus {
    pub root: Option<String>,
    pub problem: Option<String>,
    pub flavors: Vec<String>,
    pub emberlight: Option<String>,
    pub accounts: Vec<String>,
    pub game_running: bool,
    /// The game programs still running, so the member can see what to close.
    pub running: Vec<String>,
}

pub fn root(settings: &Settings) -> Result<PathBuf, String> {
    paths::find_root(settings.wow_root.as_deref().map(Path::new)).map_err(|e| e.to_string())
}

/// The WoW: Forever beta's game folder (WowB.exe), where the guild plays since October 2026.
pub const FOREVER_BETA: &str = "_classic_beta_";

/// Unless the member chose a game version, use the Forever beta whenever it is installed.
pub fn prefer_forever(settings: &mut Settings) {
    if settings.flavor_chosen {
        return;
    }
    if let Ok(root) = root(settings)
        && paths::flavor_dir(&root, FOREVER_BETA).is_ok()
    {
        settings.flavor = FOREVER_BETA.into();
    }
}

pub fn status(settings: &Settings) -> WowStatus {
    let root = root(settings);
    let running = wow::running_clients(root.as_deref().ok());
    let game_running = !running.is_empty();
    let root = match root {
        Ok(r) => r,
        Err(problem) => {
            return WowStatus { root: None, problem: Some(problem), flavors: vec![], emberlight: None, accounts: vec![], game_running, running };
        }
    };
    let flavors = paths::flavors(&root);
    let (emberlight, accounts, problem) = match paths::flavor_dir(&root, &settings.flavor) {
        Ok(dir) => (
            datafile::read_interface(&paths::addons_dir(&dir)).ok(),
            paths::saved_variables(&dir).into_iter().map(|a| a.account).collect(),
            None,
        ),
        Err(e) => (None, vec![], Some(e.to_string())),
    };
    WowStatus { root: Some(root.display().to_string()), problem, flavors, emberlight, accounts, game_running, running }
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
    report.stored = pushed.stored;
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
    let outcome = update::check_and_install(&settings.server, &dir, Some(&settings.flavor), update::RELEASE_PUBLIC_KEY, env!("CARGO_PKG_VERSION"))
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
    let (dir, _) = addons(settings)?;
    let latest = update::latest_version(&settings.server, Some(&settings.flavor), update::RELEASE_PUBLIC_KEY, env!("CARGO_PKG_VERSION"))
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

/// How Battle.net is asked to start a game folder. Retail's launch code is known and starts the
/// game. The Forever beta's is not known, so Battle.net is opened on the beta (its product id,
/// wow_classic_beta) and the member presses Play there.
#[derive(Debug, PartialEq)]
enum Start {
    Launch(&'static str),
    Open(&'static str),
}

fn start_for(flavor: &str) -> Option<Start> {
    match flavor {
        "_retail_" => Some(Start::Launch("WoW")),
        FOREVER_BETA => Some(Start::Open("wow_classic_beta")),
        _ => None,
    }
}

pub fn launch(settings: &Settings) -> Result<(), String> {
    let start = start_for(&settings.flavor).ok_or("Launching this game version is not supported yet. Start it from Battle.net.")?;
    let argument = match start {
        Start::Launch(code) => format!("--exec=\"launch {code}\""),
        Start::Open(product) => format!("--game={product}"),
    };
    launch_battle_net(&argument)
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
    fn retail_launches_and_the_forever_beta_opens_battle_net() {
        assert_eq!(start_for("_retail_"), Some(Start::Launch("WoW")));
        assert_eq!(start_for("_classic_beta_"), Some(Start::Open("wow_classic_beta")));
        assert_eq!(start_for("_ptr_"), None);
    }

    #[test]
    fn the_forever_beta_is_preferred_until_the_member_chooses() {
        let dir = std::env::temp_dir().join(format!("emberlight-flavor-test-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("_retail_")).unwrap();
        std::fs::create_dir_all(dir.join("_classic_beta_")).unwrap();
        let mut settings = Settings { wow_root: Some(dir.display().to_string()), ..Settings::default() };
        prefer_forever(&mut settings);
        assert_eq!(settings.flavor, "_classic_beta_");
        let mut chosen = Settings { wow_root: Some(dir.display().to_string()), flavor_chosen: true, ..Settings::default() };
        prefer_forever(&mut chosen);
        assert_eq!(chosen.flavor, "_retail_");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
