//! Launcher settings (a JSON file in the app's config folder) and the session token (OS keychain).

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const KEYCHAIN_SERVICE: &str = "Emberlight Launcher";
/// The guild's server; members can still change it in Settings.
pub const DEFAULT_SERVER: &str = "https://emberlightrp.com";
const KEYCHAIN_USER: &str = "session";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub wow_root: Option<String>,
    pub flavor: String,
    /// The member picked the game version in Settings. Until then the app follows the guild:
    /// WoW: Forever (`_forever_`, else the beta) when it is installed (game::prefer_forever).
    pub flavor_chosen: bool,
    pub server: String,
    pub member_name: Option<String>,
    /// The signed-in Discord account's id, shown in Settings; `None` until the server sends it.
    pub discord_id: Option<String>,
    /// Install a newer addon by itself when the app opens. When off, the app only says a new
    /// version is ready and the member presses Update.
    pub auto_update_addon: bool,
    /// Closing the window keeps the app in the tray (notifications, update checks); Quit is in the
    /// tray menu. When off, closing quits unless a game session is being watched.
    pub keep_in_tray: bool,
    /// The one-time explanation shown when Close first leaves the app in the tray.
    pub tray_notice_seen: bool,
    /// The app moved this member off the finished Forever beta (game::prefer_forever) where the
    /// addon was installed: install it in WoW: Forever too, once, if updates are automatic.
    pub install_addon_after_move: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            wow_root: None,
            flavor: "_forever_".into(),
            flavor_chosen: false,
            server: DEFAULT_SERVER.into(),
            member_name: None,
            discord_id: None,
            auto_update_addon: true,
            keep_in_tray: true,
            tray_notice_seen: false,
            install_addon_after_move: false,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    pub at: i64,
    pub uploaded: usize,
    pub stored: usize,
    pub rejected: Vec<String>,
    pub downloaded: Option<usize>,
    pub note: Option<String>,
    pub error: Option<String>,
    /// What the website took, by kind, so the app can say what was sent (Companion 0.4.6).
    #[serde(default)]
    pub sent: SentCounts,
    /// How many of Emberlight's saved-data files the game has written in this game folder: none
    /// means the addon has never run there (wrong folder, or addon off). `None` in older reports.
    #[serde(default)]
    pub addon_files: Option<usize>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SentCounts {
    pub notices: usize,
    pub replies: usize,
    pub removals: usize,
    pub professions: usize,
}

/// The last addon update check: what happened, in words a member can read.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddonCheck {
    pub at: i64,
    pub message: String,
    pub error: bool,
    /// "current", "available" (a newer version is ready, not installed), "installed", "restored",
    /// "unpublished" or "failed".
    #[serde(default)]
    pub kind: String,
    /// The guild's newest published version, when the check reached the server.
    #[serde(default)]
    pub latest: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Saved {
    pub settings: Settings,
    pub last_sync: Option<SyncReport>,
    pub last_addon_check: Option<AddonCheck>,
}

pub fn load(path: &Path) -> Saved {
    fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save(path: &Path, saved: &Saved) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp: PathBuf = path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_vec_pretty(saved).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

fn entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_USER).map_err(|e| format!("The system keychain is not available ({e})."))
}

/// The keychain is read once per launch and the answer kept in memory: every keychain read can
/// show a system prompt (macOS asks each time for unsigned builds).
static TOKEN: Mutex<Option<Option<String>>> = Mutex::new(None);

pub fn token() -> Option<String> {
    let mut cached = TOKEN.lock().expect("token lock");
    cached.get_or_insert_with(|| entry().ok()?.get_password().ok()).clone()
}

pub fn set_token(token: &str) -> Result<(), String> {
    entry()?.set_password(token).map_err(|e| format!("Could not save the sign-in to the keychain ({e})."))?;
    *TOKEN.lock().expect("token lock") = Some(Some(token.to_owned()));
    Ok(())
}

/// Forget the sign-in. This launch is signed out whatever happens; an error says the keychain
/// still holds it, so it would come back at the next start.
pub fn clear_token() -> Result<(), String> {
    *TOKEN.lock().expect("token lock") = Some(None);
    match entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("The keychain could not remove the saved sign-in ({e}).")),
    }
}
