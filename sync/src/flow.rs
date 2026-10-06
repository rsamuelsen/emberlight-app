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
    pub stored: usize,
    pub unchanged: usize,
    pub expired: usize,
    /// Why records were refused, or files could not be read. Written for members.
    pub problems: Vec<String>,
}

fn tally(report: &mut PushReport, results: &[UploadResult]) {
    for r in results {
        match r.status.as_str() {
            "stored" => report.stored += 1,
            "unchanged" => report.unchanged += 1,
            "expired" => report.expired += 1,
            _ => report.problems.push(r.reason.clone().unwrap_or_else(|| "refused by the server".into())),
        }
    }
}

/// Upload the notices and replies written by this member's verified characters.
pub fn push(client: &Client, files: &[PathBuf], now: i64) -> Result<PushReport> {
    let me = client.me()?;
    let characters: Vec<String> = me.characters.into_iter().map(|c| c.name).collect();
    let mut report = PushReport::default();
    let (mut notices, mut replies, mut removals, mut proofs) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for file in files {
        let parsed = std::fs::read(file).map_err(anyhow::Error::from).and_then(|b| Ok(lua::parse(&b)?)).and_then(|g| {
            proofs.extend(records::export_proofs(&g));
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
    let notices = records::select_uploads(notices, &characters, &me.scopes, me.party_scopes);
    let replies = records::select_reply_uploads(replies, &characters, &me.scopes, me.party_scopes);
    let removals = records::select_removal_uploads(removals, &characters, &me.scopes, me.party_scopes);
    report.notices = notices.len();
    report.replies = replies.len();
    report.removals = removals.len();
    // Notices first: a reply is only accepted once the server knows its notice.
    if !notices.is_empty() {
        tally(&mut report, &client.upload(&notices)?);
    }
    if !replies.is_empty() {
        tally(&mut report, &client.upload_replies(&replies)?);
    }
    // Only an officer's own removals; for anyone else the server refuses them, so none are sent.
    if !removals.is_empty() && me.officer {
        tally(&mut report, &client.upload_removals(&removals)?);
    }
    // Proofs are only evidence for officers; one the server cannot match changes nothing and is
    // not a problem worth showing.
    proofs.retain(|p: &records::Proof| now - p.seen_at < 7 * 86400);
    proofs.truncate(50);
    if !proofs.is_empty() {
        report.proofs = proofs.len();
        client.upload_proofs(&proofs)?;
    }
    Ok(report)
}

/// Download the guild's records into `<addons>/Emberlight_Data`. The caller must first make sure
/// the game is not running; `still_closed` is asked again after the download, right before the
/// files are written, since the game can be started (from Battle.net) while it downloads.
pub fn pull(client: &Client, addons: &Path, still_closed: impl FnOnce() -> Result<()>) -> Result<WriteReport> {
    let download = client.download()?;
    still_closed()?;
    datafile::write_data_addon(addons, &Archive { generated: download.generated, notices: download.notices, replies: download.replies, removed: download.removed })
}
