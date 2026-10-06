use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use emberlight_sync::{api, datafile, flow, lua, paths, records, update, wow};
use serde::Deserialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Emberlight sync tool (proof of concept).
#[derive(Parser)]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Show the WoW install, game folders, Emberlight accounts and whether the game is running.
    Scan {
        #[arg(long)]
        wow: Option<PathBuf>,
    },
    /// Print the guild notices in an Emberlight SavedVariables file as JSON.
    Export {
        file: PathBuf,
        /// Unix time used to drop expired notices (default: now).
        #[arg(long)]
        now: Option<i64>,
        /// Keep notices that have already expired.
        #[arg(long)]
        include_expired: bool,
    },
    /// Install notices from a JSON file into the Emberlight_Data addon.
    WriteData {
        /// JSON with a "notices" array, as printed by `export` or returned by the server.
        #[arg(long)]
        input: PathBuf,
        #[command(flatten)]
        target: Target,
    },
    /// Upload your own characters' notices to the server. Needs EMBERLIGHT_TOKEN.
    Push {
        #[arg(long, env = "EMBERLIGHT_SERVER")]
        server: String,
        /// SavedVariables files to read, instead of every account under --wow/--flavor.
        #[arg(long)]
        file: Vec<PathBuf>,
        #[arg(long)]
        wow: Option<PathBuf>,
        #[arg(long, default_value = "_retail_")]
        flavor: String,
    },
    /// Install or update the Emberlight addon from the server's signed release. No sign-in needed.
    InstallAddon {
        #[arg(long, env = "EMBERLIGHT_SERVER", default_value = "https://emberlightrp.com")]
        server: String,
        #[command(flatten)]
        target: Target,
        /// Trust a different release key (base64). For tests with a local server only.
        #[arg(long, hide = true)]
        release_key: Option<String>,
    },
    /// Download guild notices from the server into the Emberlight_Data addon. Needs EMBERLIGHT_TOKEN.
    Pull {
        #[arg(long, env = "EMBERLIGHT_SERVER")]
        server: String,
        #[command(flatten)]
        target: Target,
    },
}

/// Where Emberlight_Data is written.
#[derive(Args)]
struct Target {
    #[arg(long)]
    wow: Option<PathBuf>,
    #[arg(long, default_value = "_retail_")]
    flavor: String,
    /// AddOns folder to write into directly, instead of locating it from --wow/--flavor.
    #[arg(long, conflicts_with = "wow")]
    addons: Option<PathBuf>,
}

impl Target {
    /// The AddOns folder, after checking no game client is running.
    fn addons_ready(&self) -> Result<PathBuf> {
        let (addons, root) = match &self.addons {
            Some(a) => (a.clone(), None),
            None => {
                let root = paths::find_root(self.wow.as_deref())?;
                (paths::addons_dir(&paths::flavor_dir(&root, &self.flavor)?), Some(root))
            }
        };
        refuse_while_running(root.as_deref())?;
        Ok(addons)
    }
}

/// The token is read from the environment only, so it never lands in shell history.
fn client(server: &str) -> Result<api::Client> {
    let token = std::env::var("EMBERLIGHT_TOKEN").context("set EMBERLIGHT_TOKEN to your session token")?;
    api::Client::new(server, token.trim())
}

fn report_write(report: &datafile::WriteReport) {
    for s in &report.rejected {
        eprintln!("rejected {} in {}: {}", s.id, s.scope, s.reason);
    }
    println!("Wrote {} notice(s) to {}", report.written, report.dir.display());
}

#[derive(Deserialize)]
struct Incoming {
    notices: Vec<records::Notice>,
    #[serde(default)]
    replies: Vec<records::Reply>,
    #[serde(default)]
    removed: Vec<records::Removed>,
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn refuse_while_running(root: Option<&Path>) -> Result<()> {
    let running = wow::running_clients(root);
    if !running.is_empty() {
        bail!("World of Warcraft is running ({}). Exit the game first; nothing was changed.", running.join(", "));
    }
    Ok(())
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Scan { wow } => {
            let root = paths::find_root(wow.as_deref())?;
            println!("WoW folder: {}", root.display());
            let running = wow::running_clients(Some(&root));
            println!("Game running: {}", if running.is_empty() { "no".to_string() } else { running.join(", ") });
            for flavor in paths::flavors(&root) {
                let dir = root.join(&flavor);
                let addons = paths::addons_dir(&dir);
                let interface = datafile::read_interface(&addons).map_or_else(|_| "not installed".to_string(), |i| format!("interface {i}"));
                println!("\n{flavor}: Emberlight {interface}");
                let data = addons.join(datafile::ADDON_DIR).join("Data.lua");
                match fs::read(&data).ok().map(|b| datafile::read_data(&b)) {
                    Some(Ok(a)) => println!("  Emberlight_Data: {} notice(s), {} reply(ies), written {}", a.notices.len(), a.replies.len(), a.generated),
                    Some(Err(e)) => println!("  Emberlight_Data: unreadable ({e})"),
                    None => println!("  Emberlight_Data: not installed"),
                }
                for acc in paths::saved_variables(&dir) {
                    println!("  account {}: {}", acc.account, acc.path.display());
                }
            }
        }
        Command::Export { file, now: at, include_expired } => {
            let src = fs::read(&file).with_context(|| format!("cannot read {}", file.display()))?;
            let globals = lua::parse(&src).with_context(|| format!("{} is not a readable SavedVariables file", file.display()))?;
            let cutoff = if include_expired { None } else { Some(at.unwrap_or_else(now)) };
            let export = records::export_notices(&globals, cutoff)?;
            for s in &export.skipped {
                eprintln!("skipped {} in {}: {}", s.id, s.scope, s.reason);
            }
            println!("{}", serde_json::to_string_pretty(&export)?);
        }
        Command::WriteData { input, target } => {
            let incoming: Incoming = serde_json::from_slice(&fs::read(&input).with_context(|| format!("cannot read {}", input.display()))?)
                .with_context(|| format!("{} is not notice JSON", input.display()))?;
            let archive = datafile::Archive { generated: now(), notices: incoming.notices, replies: incoming.replies, removed: incoming.removed };
            report_write(&datafile::write_data_addon(&target.addons_ready()?, &archive)?);
        }
        Command::Push { server, file, wow, flavor } => {
            let api = client(&server)?;
            let files = if file.is_empty() {
                let root = paths::find_root(wow.as_deref())?;
                paths::saved_variables(&paths::flavor_dir(&root, &flavor)?).into_iter().map(|a| a.path).collect()
            } else {
                file
            };
            if files.is_empty() {
                bail!("no Emberlight SavedVariables found; log in and out of WoW once with Emberlight enabled");
            }
            let r = flow::push(&api, &files, now())?;
            for p in &r.problems {
                eprintln!("{p}");
            }
            println!(
                "Uploaded {} notice(s), {} reply(ies) and {} officer removal(s): {} stored, {} already current, {} expired, {} not accepted",
                r.notices,
                r.replies,
                r.removals,
                r.stored,
                r.unchanged,
                r.expired,
                r.problems.len()
            );
        }
        Command::InstallAddon { server, target, release_key } => {
            let addons = target.addons_ready()?;
            let key = release_key.as_deref().unwrap_or(update::RELEASE_PUBLIC_KEY);
            let flavor = target.addons.is_none().then_some(target.flavor.as_str());
            match update::check_and_install(&server, &addons, flavor, key, env!("CARGO_PKG_VERSION"))? {
                update::Outcome::UpToDate(v) => println!("Emberlight {v} is up to date."),
                update::Outcome::NotPublished => println!("No Emberlight release is published yet; nothing was changed."),
                update::Outcome::Installed(i) => match i.previous {
                    Some(p) => println!("Updated Emberlight from {p} to {}.", i.version),
                    None => println!("Installed Emberlight {}.", i.version),
                },
            }
        }
        Command::Pull { server, target } => {
            let api = client(&server)?;
            let addons = target.addons_ready()?;
            report_write(&flow::pull(&api, &addons, || target.addons_ready().map(|_| ()))?);
        }
    }
    Ok(())
}
