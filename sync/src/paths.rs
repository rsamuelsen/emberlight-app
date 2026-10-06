//! World of Warcraft install layout on Windows and macOS.
//!
//! `<root>/<flavor>/Interface/AddOns` holds addons; account-wide SavedVariables are at
//! `<root>/<flavor>/WTF/Account/<ACCOUNT>/SavedVariables/Emberlight.lua`. One Battle.net login
//! can own several WoW accounts, so there can be more than one file.

use anyhow::{Context, Result, bail};
use std::fs;
use std::path::{Path, PathBuf};

pub const SAVED_VARIABLES_FILE: &str = "Emberlight.lua";

/// Where to look for World of Warcraft: what the Windows installer recorded first, then the usual
/// folders.
pub fn default_roots() -> Vec<PathBuf> {
    let mut roots = registry_roots();
    if cfg!(windows) {
        roots.push(PathBuf::from(r"C:\Program Files (x86)\World of Warcraft"));
        roots.push(PathBuf::from(r"C:\Program Files\World of Warcraft"));
    } else if cfg!(target_os = "macos") {
        roots.push(PathBuf::from("/Applications/World of Warcraft"));
    }
    roots
}

/// Blizzard records a game folder such as `...\World of Warcraft\_retail_\`; the WoW folder is
/// its parent. A path that is already the WoW folder is kept.
pub fn root_from_install_path(install: &str) -> PathBuf {
    let path = PathBuf::from(install.trim().trim_end_matches(['\\', '/']));
    match path.file_name().and_then(|n| n.to_str()) {
        Some(name) if valid_flavor(name) => path.parent().map(Path::to_path_buf).unwrap_or(path),
        _ => path,
    }
}

#[cfg(windows)]
fn registry_value(keys: &[&str], name: &str) -> Vec<String> {
    use winreg::RegKey;
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    let mut out = Vec::new();
    for hive in [HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER] {
        for key in keys {
            if let Ok(value) = RegKey::predef(hive).open_subkey(key).and_then(|k| k.get_value::<String, _>(name)) {
                out.push(value);
            }
        }
    }
    out
}

#[cfg(windows)]
fn registry_roots() -> Vec<PathBuf> {
    registry_value(
        &[r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft", r"SOFTWARE\Blizzard Entertainment\World of Warcraft"],
        "InstallPath",
    )
    .iter()
    .map(|p| root_from_install_path(p))
    .collect()
}

#[cfg(not(windows))]
fn registry_roots() -> Vec<PathBuf> {
    Vec::new()
}

/// Battle.net's launcher program on Windows: where its installer says it is, then the usual folders.
#[cfg(windows)]
pub fn battle_net_exe() -> Option<PathBuf> {
    registry_value(
        &[r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net", r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net"],
        "InstallLocation",
    )
    .into_iter()
    .map(|dir| PathBuf::from(dir.trim()).join("Battle.net.exe"))
    .chain([r"C:\Program Files (x86)\Battle.net\Battle.net.exe", r"C:\Program Files\Battle.net\Battle.net.exe"].map(PathBuf::from))
    .find(|p| p.is_file())
}

pub fn find_root(explicit: Option<&Path>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        if !p.is_dir() {
            bail!("{} is not a folder", p.display());
        }
        return Ok(p.to_path_buf());
    }
    default_roots()
        .into_iter()
        .find(|p| p.is_dir())
        .context("World of Warcraft was not found in the usual place; pass --wow <folder>")
}

/// Game flavor folders look like `_retail_`, `_classic_`, `_ptr_`. The Forever folder name is
/// not known yet, so any name of that shape is accepted.
pub fn valid_flavor(name: &str) -> bool {
    name.len() >= 3
        && name.starts_with('_')
        && name.ends_with('_')
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

pub fn flavors(root: &Path) -> Vec<String> {
    let mut out: Vec<String> = fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| valid_flavor(n))
        .collect();
    out.sort();
    out
}

pub fn flavor_dir(root: &Path, flavor: &str) -> Result<PathBuf> {
    if !valid_flavor(flavor) {
        bail!("'{flavor}' is not a game folder name like _retail_");
    }
    let dir = root.join(flavor);
    if !dir.is_dir() {
        bail!("{} does not exist", dir.display());
    }
    Ok(dir)
}

pub fn addons_dir(flavor_dir: &Path) -> PathBuf {
    flavor_dir.join("Interface").join("AddOns")
}

pub struct AccountFile {
    pub account: String,
    pub path: PathBuf,
}

pub fn saved_variables(flavor_dir: &Path) -> Vec<AccountFile> {
    let accounts = flavor_dir.join("WTF").join("Account");
    let mut out: Vec<AccountFile> = fs::read_dir(&accounts)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| {
            let path = e.path().join("SavedVariables").join(SAVED_VARIABLES_FILE);
            let account = e.file_name().into_string().ok()?;
            path.is_file().then_some(AccountFile { account, path })
        })
        .collect();
    out.sort_by(|a, b| a.account.cmp(&b.account));
    out
}

/// "Name-Realm" of every character that has logged in from this game folder. The game makes a
/// folder `WTF/Account/<account>/<realm>/<character>` the first time a character is played, with
/// or without addons. The realm is written the way the game reports it to addons (no spaces or
/// hyphens).
pub fn character_folders(flavor_dir: &Path) -> Vec<String> {
    let dirs = |p: PathBuf| fs::read_dir(p).into_iter().flatten().flatten().filter(|e| e.path().is_dir());
    let name = |e: &fs::DirEntry| e.file_name().into_string().ok();
    let mut out: Vec<String> = dirs(flavor_dir.join("WTF").join("Account"))
        .flat_map(|account| dirs(account.path()))
        .filter(|realm| realm.file_name() != "SavedVariables")
        .flat_map(|realm| {
            let realm_name: String = name(&realm).unwrap_or_default().chars().filter(|c| !c.is_whitespace() && *c != '-').collect();
            dirs(realm.path()).filter_map(move |c| Some(format!("{}-{}", name(&c)?, realm_name))).collect::<Vec<_>>()
        })
        .filter(|full| full.len() <= 120 && !full.starts_with('-') && !full.ends_with('-') && !full.chars().any(|c| c.is_control() || c == '|'))
        .collect();
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_path_to_root() {
        let sep = std::path::MAIN_SEPARATOR;
        let root = format!("C:{sep}Games{sep}World of Warcraft");
        assert_eq!(root_from_install_path(&format!("{root}{sep}_retail_{sep}")), PathBuf::from(&root));
        assert_eq!(root_from_install_path(&format!("{root}{sep}_classic_")), PathBuf::from(&root));
        assert_eq!(root_from_install_path(&format!("  {root}{sep}  ")), PathBuf::from(&root));
        assert_eq!(root_from_install_path(&root), PathBuf::from(&root));
    }

    #[test]
    fn flavor_names() {
        assert!(valid_flavor("_retail_"));
        assert!(valid_flavor("_classic_era_"));
        assert!(!valid_flavor("Interface"));
        assert!(!valid_flavor("_../_"));
        assert!(!valid_flavor("_"));
    }

    #[test]
    fn finds_account_files() {
        let root = tempfile::tempdir().unwrap();
        let flavor = root.path().join("_retail_");
        for acc in ["WOW1", "123456#1", "EMPTY"] {
            fs::create_dir_all(flavor.join("WTF/Account").join(acc).join("SavedVariables")).unwrap();
        }
        for acc in ["WOW1", "123456#1"] {
            fs::write(flavor.join("WTF/Account").join(acc).join("SavedVariables").join(SAVED_VARIABLES_FILE), "").unwrap();
        }
        fs::create_dir_all(flavor.join("Interface/AddOns")).unwrap();
        assert_eq!(flavors(root.path()), vec!["_retail_"]);
        let found: Vec<String> = saved_variables(&flavor_dir(root.path(), "_retail_").unwrap()).into_iter().map(|a| a.account).collect();
        assert_eq!(found, vec!["123456#1", "WOW1"]);
    }

    #[test]
    fn finds_character_folders() {
        let root = tempfile::tempdir().unwrap();
        let account = root.path().join("WTF/Account");
        for dir in ["WOW1/Stormrage/Hazard", "WOW1/Argent Dawn/Mira", "WOW1/Azjol-Nerub/Tom", "WOW2/Stormrage/Hazard", "WOW1/SavedVariables/NotACharacter", "WOW1/EmptyRealm"] {
            fs::create_dir_all(account.join(dir)).unwrap();
        }
        fs::write(account.join("WOW1/Stormrage/a-file.txt"), "").unwrap();
        fs::write(account.join("WOW1/config-cache.wtf"), "").unwrap();
        assert_eq!(character_folders(root.path()), vec!["Hazard-Stormrage", "Mira-ArgentDawn", "Tom-AzjolNerub"]);
        assert!(character_folders(&root.path().join("missing")).is_empty());
    }
}
