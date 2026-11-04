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

/// The Battle.net product a game folder belongs to (`wow`, `wow_classic_beta`, ...), from the
/// `.flavor.info` file Battle.net keeps in every game folder: a header line, then the product.
pub fn game_product(flavor_dir: &Path) -> Option<String> {
    let text = fs::read_to_string(flavor_dir.join(".flavor.info")).ok()?;
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.contains('!'))
        .find(|l| l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'))
        .map(str::to_owned)
}

/// The game version Battle.net installed for `product` ("1.60.1.70755"), from the `.build.info`
/// table in the World of Warcraft folder: `|`-separated, the first line naming the columns
/// ("Version!STRING:0", "Product!STRING:0").
pub fn game_version(root: &Path, product: &str) -> Option<String> {
    let text = fs::read_to_string(root.join(".build.info")).ok()?;
    let mut lines = text.lines();
    let columns: Vec<String> = lines.next()?.split('|').map(|c| c.split('!').next().unwrap_or("").trim().to_ascii_lowercase()).collect();
    let version = columns.iter().position(|c| c == "version")?;
    let product_at = columns.iter().position(|c| c == "product")?;
    lines.map(|l| l.split('|').map(str::trim).collect::<Vec<_>>()).find_map(|row| {
        (row.get(product_at) == Some(&product)).then(|| row.get(version).map(|v| (*v).to_owned())).flatten()
    })
}

/// WoW: Forever's game version starts with 1.60 (interface 16001 is 1.60.1).
pub const FOREVER_VERSION: &str = "1.60.";

/// Whether a game folder is WoW: Forever (the beta or the real game). The folder name of the real
/// game was not known before launch, so it is recognised by what Battle.net says about it: a
/// product named "forever", or a 1.60 game version.
pub fn is_forever(flavor_dir: &Path) -> bool {
    if flavor_dir.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.contains("forever")) {
        return true;
    }
    let Some(product) = game_product(flavor_dir) else { return false };
    if product.contains("forever") {
        return true;
    }
    let root = flavor_dir.parent().unwrap_or(flavor_dir);
    game_version(root, &product).is_some_and(|v| v.starts_with(FOREVER_VERSION))
}

/// Whether a game folder is a test client (beta or test realm) rather than a released game.
pub fn is_test_client(flavor_dir: &Path) -> bool {
    let name = flavor_dir.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let product = game_product(flavor_dir).unwrap_or_default();
    ["beta", "ptr"].iter().any(|t| name.contains(t) || product.contains(t)) || product.ends_with("_t")
}

/// The words an addon release can name to allow a game folder: the folder's own name, and
/// "forever" when the folder is WoW: Forever whatever its name.
pub fn folder_tags(flavor_dir: &Path) -> Vec<String> {
    let mut tags: Vec<String> = flavor_dir.file_name().and_then(|n| n.to_str()).map(str::to_owned).into_iter().collect();
    if is_forever(flavor_dir) {
        tags.push("forever".into());
    }
    tags
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

    fn game_folder(root: &Path, name: &str, product: &str) -> PathBuf {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(".flavor.info"), format!("Product Flavor!STRING:0\n{product}\n")).unwrap();
        dir
    }

    #[test]
    fn recognises_forever_by_what_battle_net_says() {
        let root = tempfile::tempdir().unwrap();
        let retail = game_folder(root.path(), "_retail_", "wow");
        let beta = game_folder(root.path(), "_classic_beta_", "wow_classic_beta");
        let live = game_folder(root.path(), "_newname_", "wow_newproduct");
        let mop = game_folder(root.path(), "_classic_", "wow_classic");
        fs::write(
            root.path().join(".build.info"),
            "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|Product!STRING:0\n\
             eu|1|aa|12.1.5.66000|wow\n\
             eu|1|bb|1.60.1.70450|wow_classic_beta\n\
             eu|1|cc|1.60.1.70755|wow_newproduct\n\
             eu|1|dd|5.5.3.65000|wow_classic\n",
        )
        .unwrap();
        assert_eq!(game_product(&live).as_deref(), Some("wow_newproduct"));
        assert_eq!(game_version(root.path(), "wow_newproduct").as_deref(), Some("1.60.1.70755"));
        assert!(is_forever(&beta) && is_forever(&live));
        assert!(!is_forever(&retail) && !is_forever(&mop));
        assert!(is_test_client(&beta) && !is_test_client(&live));
        assert_eq!(folder_tags(&live), vec!["_newname_", "forever"]);
        assert_eq!(folder_tags(&retail), vec!["_retail_"]);
        // Named after Forever, or with no Battle.net files at all.
        assert!(is_forever(&game_folder(root.path(), "_forever_", "x")));
        fs::create_dir_all(root.path().join("_bare_")).unwrap();
        assert!(!is_forever(&root.path().join("_bare_")));
    }

    #[test]
    fn finds_character_folders() {
        let root = tempfile::tempdir().unwrap();
        let account = root.path().join("WTF/Account");
        for dir in ["WOW1/Stormrage/Alice", "WOW1/Argent Dawn/Mira", "WOW1/Azjol-Nerub/Tom", "WOW2/Stormrage/Alice", "WOW1/SavedVariables/NotACharacter", "WOW1/EmptyRealm"] {
            fs::create_dir_all(account.join(dir)).unwrap();
        }
        fs::write(account.join("WOW1/Stormrage/a-file.txt"), "").unwrap();
        fs::write(account.join("WOW1/config-cache.wtf"), "").unwrap();
        assert_eq!(character_folders(root.path()), vec!["Alice-Stormrage", "Mira-ArgentDawn", "Tom-AzjolNerub"]);
        assert!(character_folders(&root.path().join("missing")).is_empty());
    }
}
