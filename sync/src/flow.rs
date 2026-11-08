//! One sync, as used by both the command-line tool and the launcher: upload this member's own
//! records from the SavedVariables files, then install the guild's records into Emberlight_Data.

use crate::api::{Client, UploadResult};
use crate::datafile::{self, Archive, WriteReport};
use crate::{lua, records};
use anyhow::Result;
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PushReport {
    pub notices: usize,
    pub replies: usize,
    /// An officer's in-game removals uploaded for the server to apply.
    pub removals: usize,
    /// Other members' character proofs this computer saw in game, reported to the server.
    pub proofs: usize,
    /// This member's characters whose professions the website now has newer (addon 0.8.13).
    pub professions: usize,
    pub stored: usize,
    /// Of `stored`, how many were notices, replies and removals, so a member can be told what went.
    pub stored_notices: usize,
    pub stored_replies: usize,
    pub stored_removals: usize,
    pub unchanged: usize,
    pub expired: usize,
    /// Guild boards with this member's own records that the server does not sync (not uploaded).
    pub unsynced: Vec<String>,
    /// Why records were refused, or files could not be read. Written for members.
    pub problems: Vec<String>,
}

/// Count the server's answers; returns how many it stored.
fn tally(report: &mut PushReport, results: &[UploadResult]) -> usize {
    let before = report.stored;
    for r in results {
        match r.status.as_str() {
            "stored" => report.stored += 1,
            "unchanged" => report.unchanged += 1,
            "expired" => report.expired += 1,
            _ => report.problems.push(r.reason.clone().unwrap_or_else(|| "refused by the server".into())),
        }
    }
    report.stored - before
}

/// Upload the notices and replies written by this member's verified characters.
pub fn push(client: &Client, files: &[PathBuf], now: i64) -> Result<PushReport> {
    let me = client.me()?;
    let characters: Vec<String> = me.characters.into_iter().map(|c| c.name).collect();
    let mut report = PushReport::default();
    let (mut notices, mut replies, mut removals, mut proofs, mut professions) = (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let mut relayed = Vec::new();
    for file in files {
        let parsed = std::fs::read(file).map_err(anyhow::Error::from).and_then(|b| Ok(lua::parse(&b)?)).and_then(|g| {
            proofs.extend(records::export_proofs(&g));
            professions.extend(records::export_professions(&g));
            relayed.extend(records::export_relayed_professions(&g));
            records::export_notices(&g, Some(now))
        });
        match parsed {
            Ok(export) => {
                notices.extend(export.notices);
                replies.extend(export.replies);
                removals.extend(export.removals);
            }
            Err(e) => report.problems.push(format!("Could not read {}: {e:#}", file.display())),
        }
    }
    report.unsynced = records::unsynced_boards(&notices, &replies, &characters, &me.scopes);
    let notices = records::select_uploads(notices, &characters, &me.scopes, me.party_scopes);
    let replies = records::select_reply_uploads(replies, &characters, &me.scopes, me.party_scopes);
    let removals = records::select_removal_uploads(removals, &characters, &me.scopes, me.party_scopes);
    report.notices = notices.len();
    report.replies = replies.len();
    report.removals = removals.len();
    // Notices first: a reply is only accepted once the server knows its notice.
    if !notices.is_empty() {
        report.stored_notices = tally(&mut report, &client.upload(&notices)?);
    }
    if !replies.is_empty() {
        report.stored_replies = tally(&mut report, &client.upload_replies(&replies)?);
    }
    // Only an officer's own removals; for anyone else the server refuses them, so none are sent.
    if !removals.is_empty() && me.officer {
        report.stored_removals = tally(&mut report, &client.upload_removals(&removals)?);
    }
    // Proofs are only evidence for officers; one the server cannot match changes nothing and is
    // not a problem worth showing.
    proofs.retain(|p: &records::Proof| now - p.seen_at < 7 * 86400);
    proofs.truncate(50);
    if !proofs.is_empty() {
        report.proofs = proofs.len();
        client.upload_proofs(&proofs)?;
    }
    // Professions for the website's Professions page: only this member's own verified characters.
    // The server keeps the newest scan of each and answers "unchanged" for the rest, so sending
    // them at every sync is cheap. Optional: a failure (an older server) never stops the sync.
    professions.retain(|p: &records::ProfessionScan| records::owns(&characters, &p.character) && now - p.scanned_at < 365 * 86400);
    professions.sort_by_key(|p| std::cmp::Reverse(p.scanned_at));
    let mut seen = std::collections::HashSet::new();
    professions.retain(|p| seen.insert(p.character.clone()));
    professions.truncate(40);
    if !professions.is_empty()
        && let Ok(results) = client.upload_professions(&professions)
    {
        report.professions = results.iter().filter(|r| r.status == "stored").count();
    }
    // Guildmates' professions their addons shared in game (members without the Companion). Not
    // this member's own characters (sent above), newest share of each, from the last two weeks.
    // The server stores each once and keeps a member's own report first. Optional, like the above.
    relayed.retain(|p: &records::ProfessionScan| !records::owns(&characters, &p.character) && now - p.scanned_at < 14 * 86400);
    relayed.sort_by_key(|p| std::cmp::Reverse(p.scanned_at));
    let mut seen = std::collections::HashSet::new();
    relayed.retain(|p| seen.insert(p.character.clone()));
    relayed.truncate(40);
    if !relayed.is_empty()
        && let Ok(results) = client.upload_relayed_professions(&relayed)
    {
        report.professions += results.iter().filter(|r| r.status == "stored").count();
    }
    Ok(report)
}

/// Download the guild's records into `<addons>/Emberlight_Data`. The caller must first make sure
/// the game is not running; `still_closed` is asked again after the download, right before the
/// files are written, since the game can be started (from Battle.net) while it downloads.
///
/// For an officer it also writes the website's member list for the addon's roster check; for
/// anyone else it clears it. A failed roster download never stops the notices: the list from the
/// last sync stays (the addon shows when it was made) and the report says why.
pub fn pull(client: &Client, addons: &Path, still_closed: impl FnOnce() -> Result<()>) -> Result<WriteReport> {
    let download = client.download()?;
    let roster = client.roster_check();
    // Crafting requests for the game (addon 0.8.13). Optional: a failure leaves the last file.
    let crafting = client.craft_requests();
    still_closed()?;
    let mut report = datafile::write_data_addon(addons, &Archive { generated: download.generated, notices: download.notices, replies: download.replies, removed: download.removed })?;
    match roster {
        Ok(roster) => {
            datafile::write_roster(addons, roster.as_ref())?;
            report.roster = roster.map(|r| r.members.len());
        }
        Err(e) => report.roster_problem = Some(format!("{e:#}")),
    }
    if let Ok(crafting) = crafting {
        datafile::write_crafting(addons, crafting.as_ref())?;
    }
    Ok(report)
}
