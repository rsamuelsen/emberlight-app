//! Installing and updating the Emberlight addon from signed releases on the Emberlight server.
//!
//! A release is `manifest.json` = `{ payload, signature }`: `payload` is JSON text describing the
//! zip (version, size, SHA-256), `signature` an Ed25519 signature of those exact bytes made with
//! the release key, which only exists on the release maker's machine. The launcher trusts nothing
//! else: a manifest with a bad signature, a zip with the wrong size or hash, or a zip containing
//! anything outside `Emberlight/` is refused. Only `Interface/AddOns/Emberlight` is replaced;
//! SavedVariables live under `WTF/` and are never touched. The previous version is kept next to
//! AddOns and restored if the swap fails.

use anyhow::{Context, Result, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Component, Path, PathBuf};

/// The public half of the release key (`server/scripts/release-keygen.mjs`).
pub const RELEASE_PUBLIC_KEY: &str = "SXa+MmsjhVJq9e5OQop8qCBCgVHMCfPS/97ZQpIIw10=";

pub const ADDON: &str = "Emberlight";
const MAX_ZIP: u64 = 32 * 1024 * 1024;
const MAX_UNPACKED: u64 = 96 * 1024 * 1024;
const MAX_FILES: usize = 500;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    pub format: u32,
    pub addon: String,
    pub version: String,
    pub interface: String,
    pub flavors: Vec<String>,
    pub file: String,
    pub size: u64,
    pub sha256: String,
    pub published: i64,
    pub min_launcher: String,
}

#[derive(Deserialize)]
struct Envelope {
    payload: String,
    signature: String,
}

/// Check the manifest's signature against `public_key` (base64 of 32 bytes) and read it.
pub fn verify_manifest(bytes: &[u8], public_key: &str) -> Result<Release> {
    let envelope: Envelope = serde_json::from_slice(bytes).context("the update information is not readable")?;
    let key: [u8; 32] = STANDARD.decode(public_key)?.try_into().map_err(|_| anyhow::anyhow!("bad release key"))?;
    let signature: [u8; 64] = STANDARD
        .decode(envelope.signature.trim())
        .ok()
        .and_then(|s| s.try_into().ok())
        .context("the update is not signed")?;
    VerifyingKey::from_bytes(&key)?
        .verify_strict(envelope.payload.as_bytes(), &Signature::from_bytes(&signature))
        .map_err(|_| anyhow::anyhow!("the update's signature is not valid; it was not installed"))?;
    let release: Release = serde_json::from_str(&envelope.payload).context("the update information is not readable")?;
    if release.format != 1 || release.addon != ADDON {
        bail!("this update is for something else");
    }
    let file_ok = release.file.len() <= 120 && release.file.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)) && !release.file.contains("..");
    if !file_ok || version_parts(&release.version).is_none() || release.size > MAX_ZIP || release.sha256.len() != 64 {
        bail!("the update information is not valid");
    }
    Ok(release)
}

fn version_parts(v: &str) -> Option<Vec<u32>> {
    let parts: Option<Vec<u32>> = v.split('.').map(|p| p.parse().ok()).collect();
    parts.filter(|p| (2..=4).contains(&p.len()))
}

/// True when `candidate` is a strictly newer dotted version than `installed`.
pub fn is_newer(candidate: &str, installed: &str) -> bool {
    match (version_parts(candidate), version_parts(installed)) {
        (Some(mut a), Some(mut b)) => {
            a.resize(4, 0);
            b.resize(4, 0);
            a > b
        }
        (Some(_), None) => true,
        _ => false,
    }
}

/// The `## Version` in an addon folder's Emberlight.toc.
fn toc_version(folder: &Path) -> Option<String> {
    let toc = fs::read_to_string(folder.join(format!("{ADDON}.toc"))).ok()?;
    toc.lines().find_map(|l| l.strip_prefix("## Version:")).map(|v| v.trim().to_owned())
}

/// The `## Version` of the installed addon, if it is installed.
pub fn installed_version(addons: &Path) -> Option<String> {
    toc_version(&addons.join(ADDON))
}

/// Unpack `zip` into `into`, allowing only regular files inside `Emberlight/`.
fn unpack(zip: &[u8], into: &Path) -> Result<()> {
    let mut archive = zip::ZipArchive::new(Cursor::new(zip)).context("the update file is not a valid zip")?;
    if archive.len() > MAX_FILES {
        bail!("the update file has too many entries");
    }
    let mut total = 0u64;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.enclosed_name().context("the update file contains an unsafe path")?;
        let mut parts = name.components();
        if parts.next() != Some(Component::Normal(ADDON.as_ref())) || name.components().any(|c| !matches!(c, Component::Normal(_))) {
            bail!("the update file contains something outside the Emberlight folder");
        }
        if entry.is_dir() {
            fs::create_dir_all(into.join(&name))?;
            continue;
        }
        if !entry.is_file() {
            bail!("the update file contains a link or special file");
        }
        total += entry.size();
        if total > MAX_UNPACKED {
            bail!("the update file is too large when unpacked");
        }
        let target = into.join(&name);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut data = Vec::with_capacity(entry.size() as usize);
        entry.by_ref().take(MAX_UNPACKED).read_to_end(&mut data)?;
        fs::write(&target, data)?;
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub struct Installed {
    pub version: String,
    pub previous: Option<String>,
}

/// Check the zip against the verified release and replace `<addons>/Emberlight` with it. Callers
/// must first make sure the game is not running.
pub fn install(addons: &Path, release: &Release, zip: &[u8]) -> Result<Installed> {
    if zip.len() as u64 != release.size || hex(&Sha256::digest(zip)) != release.sha256.to_ascii_lowercase() {
        bail!("the downloaded update does not match its signed description; it was not installed");
    }
    let interface = addons.parent().context("unexpected AddOns folder")?;
    fs::create_dir_all(addons)?;
    let staging = interface.join("Emberlight-update");
    let previous_dir = interface.join("Emberlight-previous");
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    let staged = (|| {
        unpack(zip, &staging)?;
        let version = installed_version(&staging).context("the update has no Emberlight.toc")?;
        if version != release.version {
            bail!("the update's files say version {version}, not {}", release.version);
        }
        Ok(())
    })();
    if let Err(e) = staged {
        let _ = fs::remove_dir_all(&staging);
        return Err(e);
    }

    let live = addons.join(ADDON);
    let previous = installed_version(addons);
    if live.exists() {
        let _ = fs::remove_dir_all(&previous_dir);
        fs::rename(&live, &previous_dir).context("could not move the current addon aside (is a file in it open?)")?;
    }
    if let Err(e) = fs::rename(staging.join(ADDON), &live) {
        if previous_dir.exists() {
            let _ = fs::rename(&previous_dir, &live);
        }
        let _ = fs::remove_dir_all(&staging);
        return Err(e).context("could not put the new addon in place; the previous version was restored");
    }
    let _ = fs::remove_dir_all(&staging);
    Ok(Installed { version: release.version.clone(), previous })
}

/// Put the previously installed version back (kept by the last `install`).
pub fn restore_previous(addons: &Path) -> Result<String> {
    let interface = addons.parent().context("unexpected AddOns folder")?;
    let previous_dir = interface.join("Emberlight-previous");
    let version = toc_version(&previous_dir).context("there is no previous version to restore")?;
    let live = addons.join(ADDON);
    let aside = interface.join("Emberlight-replaced");
    let _ = fs::remove_dir_all(&aside);
    if live.exists() {
        fs::rename(&live, &aside)?;
    }
    fs::rename(&previous_dir, &live).context("could not restore the previous version")?;
    let _ = fs::remove_dir_all(&aside);
    Ok(version)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// What an update check decided.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    UpToDate(String),
    Installed(Installed),
    /// The server has no release yet (nothing was changed).
    NotPublished,
}

/// The server's address without a trailing slash, and a client for fetching releases.
fn release_client(server: &str) -> Result<(String, reqwest::blocking::Client)> {
    let base = crate::api::server_url(server)?;
    let http = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .user_agent(concat!("emberlight-sync/", env!("CARGO_PKG_VERSION")))
        .build()?;
    Ok((base.as_str().trim_end_matches('/').to_owned(), http))
}

/// The guild's newest signed release that this app may install in `flavor`, or `None` when
/// nothing is published yet.
fn fetch_release(root: &str, http: &reqwest::blocking::Client, flavor: Option<&str>, public_key: &str, app_version: &str) -> Result<Option<Release>> {
    let manifest = http.get(format!("{root}/v1/releases/addon/manifest.json")).send().context("could not reach the Emberlight server")?;
    if manifest.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !manifest.status().is_success() {
        bail!("the Emberlight server could not answer ({})", manifest.status());
    }
    let release = verify_manifest(&manifest.bytes()?, public_key)?;
    if is_newer(&release.min_launcher, app_version) {
        bail!("Emberlight {} needs a newer Emberlight Companion; update it first", release.version);
    }
    if flavor.is_some_and(|f| !release.flavors.iter().any(|r| r == f)) {
        bail!("Emberlight {} is not made for this game version", release.version);
    }
    Ok(Some(release))
}

/// Only look: the version of the guild's newest release, without installing anything.
pub fn latest_version(server: &str, flavor: Option<&str>, public_key: &str, app_version: &str) -> Result<Option<String>> {
    let (root, http) = release_client(server)?;
    Ok(fetch_release(&root, &http, flavor, public_key, app_version)?.map(|r| r.version))
}

/// Fetch the signed manifest from `server`, and install the release if it is newer than what is
/// in `addons` (or nothing is installed). `flavor` is the game folder (`_retail_`) when known.
pub fn check_and_install(server: &str, addons: &Path, flavor: Option<&str>, public_key: &str, app_version: &str) -> Result<Outcome> {
    let (root, http) = release_client(server)?;
    let Some(release) = fetch_release(&root, &http, flavor, public_key, app_version)? else {
        return Ok(Outcome::NotPublished);
    };
    let installed = installed_version(addons);
    if installed.as_deref().is_some_and(|v| !is_newer(&release.version, v)) {
        return Ok(Outcome::UpToDate(installed.unwrap_or_default()));
    }
    let res = http.get(format!("{root}/v1/releases/addon/{}", release.file)).send().context("could not download the update")?;
    if !res.status().is_success() {
        bail!("the update file is missing on the server");
    }
    if res.content_length().is_some_and(|n| n > MAX_ZIP) {
        bail!("the update file is too large");
    }
    let zip = res.bytes()?;
    Ok(Outcome::Installed(install(addons, &release, &zip)?))
}

/// Folder of the previous version kept after an update, if any.
pub fn previous_dir(addons: &Path) -> Option<PathBuf> {
    let dir = addons.parent()?.join("Emberlight-previous");
    dir.is_dir().then_some(dir)
}

/// The version kept by the last update, which `restore_previous` would put back.
pub fn previous_version(addons: &Path) -> Option<String> {
    toc_version(&previous_dir(addons)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn key() -> (SigningKey, String) {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let pk = STANDARD.encode(sk.verifying_key().to_bytes());
        (sk, pk)
    }

    fn zip_of(files: &[(&str, &str)]) -> Vec<u8> {
        let mut w = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (name, body) in files {
            w.start_file(*name, SimpleFileOptions::default()).unwrap();
            w.write_all(body.as_bytes()).unwrap();
        }
        w.finish().unwrap().into_inner()
    }

    fn addon_zip(version: &str) -> Vec<u8> {
        zip_of(&[
            ("Emberlight/Emberlight.toc", &format!("## Interface: 120100\n## Version: {version}\nCore\\Bootstrap.lua\n")),
            ("Emberlight/Core/Bootstrap.lua", "local _, E = ..."),
        ])
    }

    fn manifest(sk: &SigningKey, version: &str, zip: &[u8]) -> (Vec<u8>, Release) {
        let payload = serde_json::json!({
            "format": 1, "addon": "Emberlight", "version": version, "interface": "120100", "flavors": ["_retail_"],
            "file": format!("Emberlight-{version}.zip"), "size": zip.len(), "sha256": hex(&Sha256::digest(zip)),
            "published": 1_790_000_000, "minLauncher": "0.1.0"
        })
        .to_string();
        let signature = STANDARD.encode(sk.sign(payload.as_bytes()).to_bytes());
        let bytes = serde_json::to_vec(&serde_json::json!({ "payload": payload, "signature": signature })).unwrap();
        let release = serde_json::from_str(&payload).unwrap();
        (bytes, release)
    }

    fn wow() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let addons = dir.path().join("Interface").join("AddOns");
        fs::create_dir_all(&addons).unwrap();
        (dir, addons)
    }

    #[test]
    fn signature_is_required() {
        let (sk, pk) = key();
        let zip = addon_zip("0.7.0");
        let (bytes, release) = manifest(&sk, "0.7.0", &zip);
        assert_eq!(verify_manifest(&bytes, &pk).unwrap(), release);
        let other = STANDARD.encode(SigningKey::from_bytes(&[9u8; 32]).verifying_key().to_bytes());
        assert!(verify_manifest(&bytes, &other).unwrap_err().to_string().contains("signature"));
        let tampered = String::from_utf8(bytes).unwrap().replace("0.7.0", "9.9.9");
        assert!(verify_manifest(tampered.as_bytes(), &pk).is_err());
        assert!(verify_manifest(b"{\"payload\":\"{}\",\"signature\":\"\"}", &pk).is_err());
    }

    #[test]
    fn versions() {
        assert!(is_newer("0.6.1", "0.6.0"));
        assert!(is_newer("0.10.0", "0.9.9"));
        assert!(is_newer("1.0", "0.9.9"));
        assert!(!is_newer("0.6.0", "0.6.0"));
        assert!(!is_newer("0.5.9", "0.6.0"));
        assert!(!is_newer("0.6.0-beta", "0.5.0"));
        assert!(is_newer("0.6.0", "unknown"));
    }

    #[test]
    fn installs_fresh_then_updates_and_keeps_the_previous_version() {
        let (_dir, addons) = wow();
        let (sk, _) = key();
        let zip = addon_zip("0.6.0");
        let (_, release) = manifest(&sk, "0.6.0", &zip);
        assert_eq!(install(&addons, &release, &zip).unwrap(), Installed { version: "0.6.0".into(), previous: None });
        assert_eq!(installed_version(&addons).as_deref(), Some("0.6.0"));

        fs::write(addons.join("Emberlight").join("stale.lua"), "old file").unwrap();
        let zip2 = addon_zip("0.7.0");
        let (_, release2) = manifest(&sk, "0.7.0", &zip2);
        assert_eq!(install(&addons, &release2, &zip2).unwrap(), Installed { version: "0.7.0".into(), previous: Some("0.6.0".into()) });
        assert!(!addons.join("Emberlight").join("stale.lua").exists(), "old files do not survive an update");
        assert!(previous_dir(&addons).is_some());
        assert!(!addons.parent().unwrap().join("Emberlight-update").exists());

        assert_eq!(restore_previous(&addons).unwrap(), "0.6.0");
        assert_eq!(installed_version(&addons).as_deref(), Some("0.6.0"));
    }

    #[test]
    fn never_touches_saved_variables_or_other_addons() {
        let (dir, addons) = wow();
        let wtf = dir.path().join("WTF").join("Account").join("A").join("SavedVariables");
        fs::create_dir_all(&wtf).unwrap();
        fs::write(wtf.join("Emberlight.lua"), "EmberlightDB = {}").unwrap();
        fs::create_dir_all(addons.join("Emberlight_Data")).unwrap();
        fs::write(addons.join("Emberlight_Data").join("Data.lua"), "EmberlightArchive = {}").unwrap();
        let (sk, _) = key();
        let zip = addon_zip("0.7.0");
        let (_, release) = manifest(&sk, "0.7.0", &zip);
        install(&addons, &release, &zip).unwrap();
        assert_eq!(fs::read_to_string(wtf.join("Emberlight.lua")).unwrap(), "EmberlightDB = {}");
        assert_eq!(fs::read_to_string(addons.join("Emberlight_Data").join("Data.lua")).unwrap(), "EmberlightArchive = {}");
    }

    #[test]
    fn refuses_bad_downloads_and_leaves_the_addon_alone() {
        let (_dir, addons) = wow();
        let (sk, _) = key();
        let good = addon_zip("0.6.0");
        let (_, release) = manifest(&sk, "0.6.0", &good);
        install(&addons, &release, &good).unwrap();

        let mut corrupt = addon_zip("0.7.0");
        let (_, release2) = manifest(&sk, "0.7.0", &corrupt);
        corrupt[40] ^= 0xff;
        assert!(install(&addons, &release2, &corrupt).unwrap_err().to_string().contains("does not match"));

        for (bad, why) in [
            (zip_of(&[("Emberlight/Emberlight.toc", "## Version: 0.8.0\n"), ("../evil.lua", "x")]), "unsafe"),
            (zip_of(&[("Emberlight/Emberlight.toc", "## Version: 0.8.0\n"), ("Other/evil.lua", "x")]), "outside"),
            (zip_of(&[("Emberlight/Emberlight.toc", "## Version: 0.9.9\n")]), "version"),
        ] {
            let (_, r) = manifest(&sk, "0.8.0", &bad);
            let err = install(&addons, &r, &bad).unwrap_err().to_string();
            assert!(err.contains(why), "{why}: {err}");
        }
        assert_eq!(installed_version(&addons).as_deref(), Some("0.6.0"));
        assert!(!addons.parent().unwrap().join("evil.lua").exists());
        assert!(!addons.parent().unwrap().join("Emberlight-update").exists());
    }
}
