//! Shared guild records read from `EmberlightDB`, validated with the same bounds the addon's
//! receive handler (`N.Apply` in Emberlight/Core/Sync.lua) applies to incoming messages.
//!
//! Validation here only checks shape. Ownership is decided by the server from the uploader's
//! verified characters, never from anything in the file.

use crate::lua::{Key, Table, Value, field};
use anyhow::{Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SCHEMA_VERSION: i64 = 3;
pub const MAX_HORIZON_DAYS: i64 = 21;
const HORIZON: i64 = MAX_HORIZON_DAYS * 86400;
const MAX_REVISION: i64 = 999_999_999_999_999;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    pub scope: String,
    pub id: String,
    pub owner: String,
    pub author: String,
    pub revision: i64,
    pub created: i64,
    pub expires: i64,
    pub start: i64,
    pub category: i64,
    pub cancelled: bool,
    pub title: String,
    pub location: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Skipped {
    pub scope: String,
    pub id: String,
    pub reason: String,
}

/// A member's answer to a notice, as the addon's `R` record: one per respondent per notice.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub scope: String,
    pub notice_id: String,
    pub respondent: String,
    pub revision: i64,
    pub response: String,
    /// The member's short line with the answer (the addon's `L` record, `lines[noticeId][respondent]`),
    /// with its own revision. Both or neither; an empty line with a revision was cleared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_revision: Option<i64>,
}

/// The longest line the addon sends with an answer (`N.Line`), in bytes.
pub const MAX_LINE_BYTES: usize = 80;

/// The only answers the addon offers (`N.Reply`).
pub const RESPONSES: [&str; 2] = ["I will join", "Unable to attend"];

/// An officer's in-game removal of another member's notice (the addon's `M` record), uploaded so
/// the server can hide the notice everywhere. The server decides whether the uploader is an
/// officer and owns `moderator`; nothing here is trusted.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Removal {
    pub scope: String,
    pub id: String,
    pub moderator: String,
}

/// Another member's character seen sending a claim code in game (`/emberlight verify CODE`),
/// recorded by this client under `localData.proofs`. The server decides what it proves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Proof {
    pub character: String,
    pub code: String,
    pub seen_at: i64,
}

/// The in-game proofs this client saw (at most 50, as the addon keeps), newest first.
pub fn export_proofs(globals: &BTreeMap<String, Value>) -> Vec<Proof> {
    let mut out = Vec::new();
    let proofs = globals
        .get("EmberlightDB")
        .and_then(Value::as_table)
        .and_then(|db| field(db, "localData"))
        .and_then(Value::as_table)
        .and_then(|l| field(l, "proofs"))
        .and_then(Value::as_table);
    for p in proofs.into_iter().flat_map(|t| t.values()).filter_map(Value::as_table) {
        let text = |k: &str| field(p, k).and_then(Value::as_bytes).and_then(|b| std::str::from_utf8(b).ok()).map(str::to_owned);
        let (Some(character), Some(code), Some(seen_at)) = (text("character"), text("code"), field(p, "at").and_then(Value::as_int)) else { continue };
        if valid_owner(&character) && code.len() == 8 && code.bytes().all(|b| b.is_ascii_uppercase() || (b'2'..=b'9').contains(&b)) {
            out.push(Proof { character, code, seen_at });
        }
    }
    out.sort_by(|a, b| b.seen_at.cmp(&a.seen_at).then_with(|| (&a.character, &a.code).cmp(&(&b.character, &b.code))));
    out.dedup_by(|a, b| a.character == b.character && a.code == b.code);
    out.truncate(50);
    out
}

/// A notice the server says an officer removed (`removed` in the download).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Removed {
    pub scope: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Export {
    pub notices: Vec<Notice>,
    #[serde(default)]
    pub replies: Vec<Reply>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removals: Vec<Removal>,
    pub skipped: Vec<Skipped>,
    pub party_scopes_ignored: usize,
}

/// Addon text rule (`E.Clean`): no WoW markup pipes and no control bytes except tab/LF/CR.
fn clean(s: &str) -> bool {
    !s.bytes().any(|b| b == b'|' || matches!(b, 0..=8 | 11 | 12 | 14..=31 | 127))
}

/// Lua's `%s` class, used by the addon's `E.Trim` and `C.Canonical`.
fn lua_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
}

/// `C.Canonical`: each run of whitespace becomes `_`, ASCII letters lowercased.
pub fn canonical(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut in_space = false;
    for c in name.chars() {
        if !lua_space(c) {
            out.push(c.to_ascii_lowercase());
        } else if !in_space {
            out.push('_');
        }
        in_space = lua_space(c);
    }
    out
}

fn text(s: &str, limit: usize, required: bool, what: &str) -> Result<(), String> {
    if s.len() > limit {
        return Err(format!("{what} is longer than {limit} bytes"));
    }
    if !clean(s) {
        return Err(format!("{what} contains markup or control characters"));
    }
    if required && s.trim_matches(lua_space).is_empty() {
        return Err(format!("{what} is empty"));
    }
    Ok(())
}

/// A guild board (`region:clubId`) or a party board. Which ones sync is the server's policy.
pub fn valid_scope(scope: &str) -> bool {
    let mut parts = scope.split(':');
    let ok = |p: Option<&str>, max: usize| p.is_some_and(|p| !p.is_empty() && p.len() <= max && p.bytes().all(|b| b.is_ascii_digit()));
    (ok(parts.next(), 10) && ok(parts.next(), 20) && parts.next().is_none()) || is_party_scope(scope)
}

/// `Player-<server>-<id>`, as WoW formats a player GUID.
fn valid_guid(g: &str) -> bool {
    let mut parts = g.splitn(3, '-');
    parts.next() == Some("Player")
        && parts.next().is_some_and(|p| (1..=5).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()))
        && parts.next().is_some_and(|p| (1..=16).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_alphanumeric()))
}

/// A party board as the addon keys it (`C.Party`): `party:<leader>:<member>,<member>...`, 2-5 members.
pub fn is_party_scope(scope: &str) -> bool {
    let Some(rest) = scope.strip_prefix("party:") else { return false };
    let Some((leader, members)) = rest.split_once(':') else { return false };
    let members: Vec<&str> = members.split(',').collect();
    scope.len() <= 200 && valid_guid(leader) && (2..=5).contains(&members.len()) && members.iter().all(|m| valid_guid(m))
}

/// Whether the server syncs this board: a listed guild, or any party while its test switch is on.
pub fn scope_synced(scope: &str, guilds: &[String], party: bool) -> bool {
    guilds.iter().any(|g| g == scope) || (party && is_party_scope(scope))
}

/// Every board in the save file: guild boards and party boards.
fn boards(db: &Table) -> impl Iterator<Item = (&Key, &Value)> {
    ["guildData", "partyData"].into_iter().filter_map(|k| field(db, k).and_then(Value::as_table)).flatten()
}

/// Canonical `name-realm` as produced by `C.Canonical`: no whitespace (a space is `_`), ASCII lowercased.
pub fn valid_owner(owner: &str) -> bool {
    (3..=120).contains(&owner.len())
        && owner.contains('-')
        && clean(owner)
        && !owner.chars().any(|c| c == ':' || lua_space(c) || c.is_ascii_uppercase())
}

impl Notice {
    pub fn validate(&self) -> Result<(), String> {
        if !valid_scope(&self.scope) {
            return Err("scope is not a guild or party board".into());
        }
        if !valid_owner(&self.owner) {
            return Err("owner is not a canonical character name".into());
        }
        let serial = self.id.strip_prefix(&self.owner).and_then(|rest| rest.strip_prefix(':'));
        if self.id.len() > 150 || !serial.is_some_and(|s| !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_digit())) {
            return Err("id does not belong to its owner".into());
        }
        text(&self.author, 120, true, "author")?;
        if canonical(&self.author) != self.owner {
            return Err("author does not match owner".into());
        }
        if !(1..=MAX_REVISION).contains(&self.revision) {
            return Err("revision is out of range".into());
        }
        if self.created <= 0 || self.expires <= self.created || self.expires - self.created > HORIZON + 14400 + 120 {
            return Err("expiry is out of range".into());
        }
        if self.start < self.created - 172_800 || self.start > self.created + HORIZON + 60 {
            return Err("start time is out of range".into());
        }
        if !(1..=4).contains(&self.category) {
            return Err("category is not valid".into());
        }
        text(&self.title, 100, true, "title")?;
        text(&self.location, 100, false, "location")?;
        text(&self.body, 1600, true, "body")?;
        Ok(())
    }
}

/// The owner part of a notice id (`owner:serial`), if the id is well formed.
pub fn notice_owner(id: &str) -> Option<&str> {
    let (owner, serial) = id.rsplit_once(':')?;
    (id.len() <= 150 && valid_owner(owner) && !serial.is_empty() && serial.len() <= 20 && serial.bytes().all(|b| b.is_ascii_digit())).then_some(owner)
}

impl Reply {
    pub fn validate(&self) -> Result<(), String> {
        if !valid_scope(&self.scope) {
            return Err("scope is not a guild or party board".into());
        }
        let owner = notice_owner(&self.notice_id).ok_or("notice id is not valid")?;
        if !valid_owner(&self.respondent) {
            return Err("respondent is not a canonical character name".into());
        }
        if owner == self.respondent {
            return Err("authors do not answer their own notice".into());
        }
        if !(1..=MAX_REVISION).contains(&self.revision) {
            return Err("revision is out of range".into());
        }
        if !RESPONSES.contains(&self.response.as_str()) {
            return Err("answer is not one the addon offers".into());
        }
        match (&self.line, self.line_revision) {
            (None, None) => Ok(()),
            (Some(line), Some(revision)) => validate_line(line, revision),
            _ => Err("line comes without its revision".into()),
        }
    }
}

fn validate_line(line: &str, revision: i64) -> Result<(), String> {
    if line.len() > MAX_LINE_BYTES || !clean(line) {
        return Err("line is longer than 80 bytes or contains markup".into());
    }
    if !(1..=MAX_REVISION).contains(&revision) {
        return Err("line revision is out of range".into());
    }
    Ok(())
}

impl Reply {
    /// Keep the newer of two copies' lines (the answer and the line have separate revisions).
    fn take_newer_line(&mut self, other: &Reply) {
        if other.line_revision.unwrap_or(0) > self.line_revision.unwrap_or(0) {
            self.line = other.line.clone();
            self.line_revision = other.line_revision;
        }
    }
}

/// The addon truncates by bytes, which can cut a multi-byte character in half at the end.
/// Drop only that incomplete tail; anything else invalid is rejected.
fn utf8(bytes: &[u8]) -> Result<String, String> {
    match std::str::from_utf8(bytes) {
        Ok(s) => Ok(s.to_owned()),
        Err(e) if e.error_len().is_none() => Ok(std::str::from_utf8(&bytes[..e.valid_up_to()]).expect("valid prefix").to_owned()),
        Err(_) => Err("text is not valid UTF-8".into()),
    }
}

fn get_str(t: &Table, name: &str, optional: bool) -> Result<String, String> {
    match field(t, name) {
        None if optional => Ok(String::new()),
        Some(Value::Str(b)) => utf8(b),
        _ => Err(format!("missing {name}")),
    }
}

fn get_int(t: &Table, name: &str) -> Result<i64, String> {
    field(t, name).and_then(Value::as_int).ok_or_else(|| format!("missing {name}"))
}

fn notice_from(scope: &str, id: &str, t: &Table) -> Result<Notice, String> {
    let notice = Notice {
        scope: scope.to_owned(),
        id: id.to_owned(),
        owner: get_str(t, "owner", false)?,
        author: get_str(t, "author", false)?,
        revision: get_int(t, "revision")?,
        created: get_int(t, "created")?,
        expires: get_int(t, "expires")?,
        start: get_int(t, "start")?,
        category: get_int(t, "categoryIndex")?,
        cancelled: field(t, "cancelled").and_then(Value::as_bool).unwrap_or(false),
        title: get_str(t, "title", false)?,
        location: get_str(t, "location", true)?,
        body: get_str(t, "body", false)?,
    };
    if get_str(t, "id", false)? != id {
        return Err("stored id does not match its key".into());
    }
    notice.validate()?;
    Ok(notice)
}

fn key_text(k: &Key) -> String {
    match k {
        Key::Int(i) => i.to_string(),
        Key::Str(s) => String::from_utf8_lossy(s).into_owned(),
    }
}

/// Read every guild-scope notice from a parsed Emberlight SavedVariables file.
/// `now` drops notices that have already expired.
pub fn export_notices(globals: &BTreeMap<String, Value>, now: Option<i64>) -> Result<Export> {
    let db = globals
        .get("EmberlightDB")
        .and_then(Value::as_table)
        .ok_or_else(|| anyhow!("this file has no Emberlight data"))?;
    match field(db, "schemaVersion").and_then(Value::as_int) {
        Some(SCHEMA_VERSION) => {}
        Some(v) if v > SCHEMA_VERSION => bail!("this data belongs to a newer Emberlight version (schema {v})"),
        _ => bail!("this data has not been opened by Emberlight 0.2 or later yet; log in once with the addon enabled"),
    }
    // Party boards the addon made that are not in the expected shape; nothing is read from them.
    let party_scopes_ignored = field(db, "partyData").and_then(Value::as_table).map_or(0, |t| t.keys().filter(|k| !is_party_scope(&key_text(k))).count());
    let mut notices = Vec::new();
    let mut removals = Vec::new();
    let mut skipped = Vec::new();
    for (scope_key, scope) in boards(db) {
        let scope_name = key_text(scope_key);
        if !valid_scope(&scope_name) {
            continue;
        }
        let Some(entries) = scope.as_table().and_then(|s| field(s, "entries")).and_then(Value::as_table) else {
            continue;
        };
        for (id_key, entry) in entries {
            let id = key_text(id_key);
            let result = match entry.as_table() {
                None => Err("entry is not a table".to_string()),
                Some(t) => notice_from(&scope_name, &id, t),
            };
            match result {
                Ok(n) if now.is_some_and(|now| n.expires <= now) => {}
                Ok(n) => {
                    if let Some(r) = entry.as_table().and_then(|t| removal_from(&n, t)) {
                        removals.push(r);
                    }
                    notices.push(n)
                }
                Err(reason) => skipped.push(Skipped { scope: scope_name.clone(), id, reason }),
            }
        }
    }
    notices.sort_by(|a, b| (&a.scope, &a.id).cmp(&(&b.scope, &b.id)));
    let replies = export_replies(db, &notices, &mut skipped);
    removals.sort_by(|a, b| (&a.scope, &a.id).cmp(&(&b.scope, &b.id)));
    Ok(Export { notices, replies, removals, skipped, party_scopes_ignored })
}

/// The removal recorded on a notice an officer removed in game (`N.Moderate` or a received `M`
/// record): `moderated = true` and the removing character in `moderator`.
fn removal_from(n: &Notice, t: &Table) -> Option<Removal> {
    if field(t, "moderated").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let moderator = std::str::from_utf8(field(t, "moderator")?.as_bytes()?).ok()?;
    (valid_owner(moderator) && moderator != n.owner).then(|| Removal { scope: n.scope.clone(), id: n.id.clone(), moderator: moderator.to_owned() })
}

/// The name part of an identity, with its "-": `elthiern_hendil-`.
fn name_of(identity: &str) -> &str {
    identity.rfind('-').map_or("", |i| &identity[..=i])
}

/// Whether `identity` is one of these verified characters. WoW: Forever puts characters on hidden
/// realms of one megarealm ("ClassicBetaPvE", "ClassicBetaPvE2"): the game writes a character's own
/// hidden realm, the server links it with the guild's realm. Names are unique on the megarealm, so
/// the same name is the same character, whatever the realm (as the server's `identity.ts`).
pub fn owns(characters: &[String], identity: &str) -> bool {
    characters.iter().any(|c| c == identity || (!name_of(c).is_empty() && name_of(c) == name_of(identity)))
}

/// Guild boards holding this member's own notices or answers that the server does not sync, so
/// nothing in them is uploaded. The beta renumbered its region once (`90:` became `110:` for the
/// same guild); naming such a board lets the member tell an officer instead of syncing in silence.
pub fn unsynced_boards<'a>(notices: impl IntoIterator<Item = &'a Notice>, replies: impl IntoIterator<Item = &'a Reply>, characters: &[String], scopes: &[String]) -> Vec<String> {
    let own = notices.into_iter().filter(|n| owns(characters, &n.owner)).map(|n| &n.scope);
    let answered = replies.into_iter().filter(|r| owns(characters, &r.respondent)).map(|r| &r.scope);
    let mut boards: Vec<String> = own.chain(answered).filter(|s| !is_party_scope(s) && !scopes.contains(s)).cloned().collect();
    boards.sort();
    boards.dedup();
    boards
}

/// Removals this member may upload: made by one of their verified characters, in a synced board.
pub fn select_removal_uploads(removals: impl IntoIterator<Item = Removal>, characters: &[String], scopes: &[String], party: bool) -> Vec<Removal> {
    let mut picked: BTreeMap<(String, String), Removal> = BTreeMap::new();
    for r in removals {
        if owns(characters, &r.moderator) && scope_synced(&r.scope, scopes, party) {
            picked.entry((r.scope.clone(), r.id.clone())).or_insert(r);
        }
    }
    picked.into_values().collect()
}

/// Replies to the notices being exported (`replies[noticeId][respondent] = { revision, response }`).
fn export_replies(db: &Table, notices: &[Notice], skipped: &mut Vec<Skipped>) -> Vec<Reply> {
    let mut out = Vec::new();
    for n in notices {
        let replies = boards(db)
            .find(|(k, _)| key_text(k) == n.scope)
            .and_then(|(_, v)| v.as_table())
            .and_then(|s| field(s, "replies"))
            .and_then(Value::as_table)
            .and_then(|r| field(r, &n.id))
            .and_then(Value::as_table);
        let lines = boards(db)
            .find(|(k, _)| key_text(k) == n.scope)
            .and_then(|(_, v)| v.as_table())
            .and_then(|s| field(s, "lines"))
            .and_then(Value::as_table)
            .and_then(|l| field(l, &n.id))
            .and_then(Value::as_table);
        for (who, answer) in replies.into_iter().flatten() {
            let t = answer.as_table();
            let mut reply = Reply {
                scope: n.scope.clone(),
                notice_id: n.id.clone(),
                respondent: key_text(who),
                revision: t.and_then(|t| field(t, "revision")).and_then(Value::as_int).unwrap_or(0),
                response: t.and_then(|t| field(t, "response")).and_then(Value::as_bytes).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("").to_owned(),
                line: None,
                line_revision: None,
            };
            // The line (`lines[noticeId][respondent] = { revision, text }`) rides with the answer.
            // A bad line is left out rather than costing the answer.
            if let Some(l) = lines.and_then(|l| l.get(who)).and_then(Value::as_table) {
                let revision = field(l, "revision").and_then(Value::as_int).unwrap_or(0);
                match field(l, "text").and_then(Value::as_bytes).map(utf8) {
                    Some(Ok(text)) if validate_line(&text, revision).is_ok() => {
                        reply.line = Some(text);
                        reply.line_revision = Some(revision);
                    }
                    _ => skipped.push(Skipped { scope: n.scope.clone(), id: format!("{} line by {}", n.id, reply.respondent), reason: "line is not valid".into() }),
                }
            }
            match reply.validate() {
                Ok(()) => out.push(reply),
                Err(reason) => skipped.push(Skipped { scope: n.scope.clone(), id: format!("{} reply by {}", n.id, reply.respondent), reason }),
            }
        }
    }
    out.sort_by(|a, b| (&a.scope, &a.notice_id, &a.respondent).cmp(&(&b.scope, &b.notice_id, &b.respondent)));
    out
}

/// Replies this member may upload: their own verified characters, highest revision per notice.
pub fn select_reply_uploads(replies: impl IntoIterator<Item = Reply>, characters: &[String], scopes: &[String], party: bool) -> Vec<Reply> {
    let mut best: BTreeMap<(String, String, String), Reply> = BTreeMap::new();
    for r in replies {
        if !owns(characters, &r.respondent) || !scope_synced(&r.scope, scopes, party) {
            continue;
        }
        let key = (r.scope.clone(), r.notice_id.clone(), r.respondent.clone());
        match best.get_mut(&key) {
            Some(old) if old.revision >= r.revision => old.take_newer_line(&r),
            Some(old) => {
                let mut r = r;
                r.take_newer_line(old);
                *old = r;
            }
            None => {
                best.insert(key, r);
            }
        }
    }
    best.into_values().collect()
}

/// Characters that have used Emberlight on this computer, as WoW reported them ("Name-Realm").
/// Drafts are keyed by the logged-in character, and a notice marked `own` was written by one.
/// This only suggests names to claim; it proves nothing about ownership.
pub fn local_characters(globals: &BTreeMap<String, Value>) -> Vec<String> {
    let mut found = std::collections::BTreeSet::new();
    let Some(db) = globals.get("EmberlightDB").and_then(Value::as_table) else { return vec![] };
    let drafts = field(db, "localData").and_then(Value::as_table).and_then(|t| field(t, "drafts")).and_then(Value::as_table);
    for key in drafts.into_iter().flat_map(|t| t.keys()) {
        if let Key::Str(k) = key
            && let Ok(k) = std::str::from_utf8(k)
            && let Some((who, _kind)) = k.rsplit_once(':')
            && who.contains('-')
            && clean(who)
            && who.len() <= 120
        {
            found.insert(who.to_owned());
        }
    }
    for (_, scope) in boards(db) {
        let entries = scope.as_table().and_then(|s| field(s, "entries")).and_then(Value::as_table);
        for entry in entries.into_iter().flat_map(|t| t.values()).filter_map(Value::as_table) {
            if field(entry, "own").and_then(Value::as_bool) == Some(true)
                && let Some(Ok(author)) = field(entry, "author").and_then(Value::as_bytes).map(std::str::from_utf8)
                && author.contains('-')
                && clean(author)
            {
                found.insert(author.to_owned());
            }
        }
    }
    found.into_iter().collect()
}

/// Notices this member may upload: owned by one of their verified characters, in a synced
/// guild, highest revision per id when several account files hold the same notice.
pub fn select_uploads(exports: impl IntoIterator<Item = Notice>, characters: &[String], scopes: &[String], party: bool) -> Vec<Notice> {
    let mut best: BTreeMap<(String, String), Notice> = BTreeMap::new();
    for n in exports {
        if !owns(characters, &n.owner) || !scope_synced(&n.scope, scopes, party) {
            continue;
        }
        let key = (n.scope.clone(), n.id.clone());
        if best.get(&key).is_none_or(|old| old.revision < n.revision) {
            best.insert(key, n);
        }
    }
    best.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_records_in_an_unsynced_guild_are_named() {
        let mut n = sample();
        n.scope = "110:123".into();
        let mut other = sample();
        other.scope = "110:999".into();
        other.id = "bob-testrealm:1800000000000".into();
        other.owner = "bob-testrealm".into();
        let synced = sample();
        let me = ["alice-testrealm".to_string()];
        assert_eq!(unsynced_boards([&n, &other, &synced], [], &me, &["3:123".into()]), vec!["110:123".to_string()]);
        assert!(unsynced_boards([&synced], [], &me, &["3:123".into()]).is_empty());
    }

    #[test]
    fn hidden_realms_are_the_same_character() {
        let linked = ["elthiern_hendil-classicbetapve2".to_string()];
        assert!(owns(&linked, "elthiern_hendil-classicbetapve"));
        assert!(owns(&linked, "elthiern_hendil-classicbetapve2"));
        assert!(!owns(&linked, "nora_everwood-classicbetapve2"));
        assert!(!owns(&linked, "elthiern"));
        let mut n = sample();
        n.id = "alice-otherrealm:1800000000000".into();
        n.owner = "alice-otherrealm".into();
        assert_eq!(select_uploads([n.clone()], &["alice-testrealm".into()], &["3:123".into()], false), vec![n]);
    }

    #[test]
    fn upload_selection() {
        let a = sample();
        let mut newer = a.clone();
        newer.revision += 1;
        let mut other_guild = a.clone();
        other_guild.scope = "3:9".into();
        let mut bob = a.clone();
        bob.owner = "bob-testrealm".into();
        let party = Notice { scope: "party:Player-1403-0A1B2C3D:Player-1403-0A1B2C3D,Player-1403-0B2C3D4E".into(), ..newer.clone() };
        let picked = select_uploads([newer.clone(), a, other_guild, bob, party.clone()], &["alice-testrealm".into()], &["3:123".into()], false);
        assert_eq!(picked, vec![newer.clone()]);
        let with_party = select_uploads([newer.clone(), party.clone()], &["alice-testrealm".into()], &["3:123".into()], true);
        assert_eq!(with_party, vec![newer, party]);
    }

    fn sample() -> Notice {
        Notice {
            scope: "3:123".into(),
            id: "alice-testrealm:1800000000000".into(),
            owner: "alice-testrealm".into(),
            author: "Alice-TestRealm".into(),
            revision: 1_800_000_000_000,
            created: 1_800_000_000,
            expires: 1_800_007_200,
            start: 1_800_000_000,
            category: 1,
            cancelled: false,
            title: "Title".into(),
            location: String::new(),
            body: "Body".into(),
        }
    }

    fn rejected(f: impl FnOnce(&mut Notice)) -> String {
        let mut n = sample();
        f(&mut n);
        n.validate().unwrap_err()
    }

    #[test]
    fn accepts_sample() {
        sample().validate().unwrap();
    }

    #[test]
    fn rejects_forged_or_malformed() {
        assert!(rejected(|n| n.id = "bob-testrealm:1".into()).contains("owner"));
        assert!(rejected(|n| n.id = "alice-testrealm:12x".into()).contains("owner"));
        assert!(rejected(|n| n.owner = "Alice-TestRealm".into()).contains("canonical"));
        assert!(rejected(|n| n.scope = "party:abc".into()).contains("scope"));
        assert!(rejected(|n| n.title = "|Hitem|h".into()).contains("markup"));
        assert!(rejected(|n| n.body = "a\u{1}b".into()).contains("control"));
        assert!(rejected(|n| n.body = "x".repeat(1601)).contains("longer"));
        assert!(rejected(|n| n.title = "  ".into()).contains("empty"));
        assert!(rejected(|n| n.category = 5).contains("category"));
        assert!(rejected(|n| n.expires = n.created).contains("expiry"));
        assert!(rejected(|n| n.expires = n.created + 60 * 86400).contains("expiry"));
        assert!(rejected(|n| n.start = n.created + 30 * 86400).contains("start"));
        assert!(rejected(|n| n.revision = 0).contains("revision"));
    }

    #[test]
    fn reply_rules() {
        let ok = Reply {
            scope: "3:123".into(),
            notice_id: "alice-testrealm:1800000000000".into(),
            respondent: "bob-testrealm".into(),
            revision: 5,
            response: "I will join".into(),
            line: None,
            line_revision: None,
        };
        ok.validate().unwrap();
        let bad = |f: fn(&mut Reply)| {
            let mut r = ok.clone();
            f(&mut r);
            r.validate().unwrap_err()
        };
        assert!(bad(|r| r.respondent = "alice-testrealm".into()).contains("own notice"));
        assert!(bad(|r| r.response = "Maybe".into()).contains("answer"));
        assert!(bad(|r| r.notice_id = "alice-testrealm".into()).contains("notice id"));
        assert!(bad(|r| r.revision = 0).contains("revision"));
        assert!(bad(|r| r.respondent = "Bob".into()).contains("respondent"));
        let mine = select_reply_uploads(
            [ok.clone(), Reply { revision: 9, ..ok.clone() }, Reply { respondent: "carol-testrealm".into(), ..ok.clone() }],
            &["bob-testrealm".into()],
            &["3:123".into()],
            false,
        );
        assert_eq!(mine, vec![Reply { revision: 9, ..ok }]);
    }

    #[test]
    fn removals_are_read_from_moderated_notices() {
        let src = br#"EmberlightDB = { schemaVersion = 3, guildData = { ["3:123"] = { entries = {
            ["alice-testrealm:1800000000000"] = { id = "alice-testrealm:1800000000000", owner = "alice-testrealm", author = "Alice-TestRealm",
              revision = 1800000000000, created = 1800000000, expires = 1800007200, start = 1800000000, categoryIndex = 1,
              cancelled = true, moderated = true, moderator = "keeper-testrealm", modRevision = 1800000000500,
              title = "Title", location = "", body = "Body" },
            ["alice-testrealm:1800000000001"] = { id = "alice-testrealm:1800000000001", owner = "alice-testrealm", author = "Alice-TestRealm",
              revision = 1800000000001, created = 1800000000, expires = 1800007200, start = 1800000000, categoryIndex = 1,
              cancelled = true, title = "Withdrawn", location = "", body = "Body" },
        } } } }"#;
        let export = export_notices(&crate::lua::parse(src).unwrap(), None).unwrap();
        let removal = Removal { scope: "3:123".into(), id: "alice-testrealm:1800000000000".into(), moderator: "keeper-testrealm".into() };
        assert_eq!(export.removals, vec![removal.clone()]);
        assert_eq!(select_removal_uploads(export.removals.clone(), &["keeper-testrealm".into()], &["3:123".into()], false), vec![removal]);
        assert!(select_removal_uploads(export.removals.clone(), &["alice-testrealm".into()], &["3:123".into()], false).is_empty());
        assert!(select_removal_uploads(export.removals, &["keeper-testrealm".into()], &["3:9".into()], false).is_empty());
    }

    #[test]
    fn reply_lines_ride_with_their_answer() {
        let src = br#"EmberlightDB = { schemaVersion = 3, guildData = { ["3:123"] = {
            entries = { ["alice-testrealm:1800000000000"] = { id = "alice-testrealm:1800000000000", owner = "alice-testrealm", author = "Alice-TestRealm",
              revision = 1800000000000, created = 1800000000, expires = 1800007200, start = 1800000000, categoryIndex = 1,
              cancelled = false, title = "Title", location = "", body = "Body" } },
            replies = { ["alice-testrealm:1800000000000"] = {
              ["bob-testrealm"] = { revision = 5, response = "I will join" },
              ["carol-testrealm"] = { revision = 6, response = "I will join" },
              ["dave-testrealm"] = { revision = 7, response = "Unable to attend" } } },
            lines = { ["alice-testrealm:1800000000000"] = {
              ["bob-testrealm"] = { revision = 8, text = "as the caravan guard" },
              ["carol-testrealm"] = { revision = 9, text = "|cffff0000red" } } },
        } } }"#;
        let export = export_notices(&crate::lua::parse(src).unwrap(), None).unwrap();
        let bob = export.replies.iter().find(|r| r.respondent == "bob-testrealm").unwrap();
        assert_eq!((bob.line.as_deref(), bob.line_revision), (Some("as the caravan guard"), Some(8)));
        // A bad line is skipped; the answer still goes up.
        let carol = export.replies.iter().find(|r| r.respondent == "carol-testrealm").unwrap();
        assert_eq!((carol.line.as_ref(), carol.line_revision), (None, None));
        assert!(export.skipped.iter().any(|s| s.id.contains("line by carol-testrealm")));
        let dave = export.replies.iter().find(|r| r.respondent == "dave-testrealm").unwrap();
        assert_eq!(dave.line, None);
        // Two copies of the same answer (two installs): the newer answer and the newer line win separately.
        let older_answer_newer_line = Reply { revision: 4, line: Some("with my hound".into()), line_revision: Some(10), ..bob.clone() };
        let picked = select_reply_uploads([bob.clone(), older_answer_newer_line], &["bob-testrealm".into()], &["3:123".into()], false);
        assert_eq!(picked, vec![Reply { line: Some("with my hound".into()), line_revision: Some(10), ..bob.clone() }]);
        // The JSON the server receives has the two fields only when there is a line.
        let json = serde_json::to_value(&picked[0]).unwrap();
        assert_eq!((json["line"].as_str(), json["lineRevision"].as_i64()), (Some("with my hound"), Some(10)));
        assert!(serde_json::to_value(dave).unwrap().get("line").is_none());
        let bad = |f: fn(&mut Reply)| {
            let mut r = bob.clone();
            f(&mut r);
            r.validate().unwrap_err()
        };
        assert!(bad(|r| r.line_revision = None).contains("revision"));
        assert!(bad(|r| r.line = Some("x".repeat(81))).contains("80 bytes"));
        assert!(bad(|r| r.line_revision = Some(0)).contains("line revision"));
    }

    #[test]
    fn proofs_are_read_from_local_data() {
        let src = br#"EmberlightDB = { schemaVersion = 3, localData = { proofs = {
            ["aeloria-testrealm|ABCD2345"] = { character = "aeloria-testrealm", code = "ABCD2345", at = 1800000000 },
            ["x|bad"] = { character = "Not Canonical", code = "ABCD2345", at = 1 },
            ["y|bad"] = { character = "bob-testrealm", code = "abcd2345", at = 1 },
        } } }"#;
        let proofs = export_proofs(&crate::lua::parse(src).unwrap());
        assert_eq!(proofs, vec![Proof { character: "aeloria-testrealm".into(), code: "ABCD2345".into(), seen_at: 1_800_000_000 }]);
    }

    #[test]
    fn party_board_keys() {
        assert!(is_party_scope("party:Player-1403-0A1B2C3D:Player-1403-0A1B2C3D,Player-1403-0B2C3D4E"));
        assert!(is_party_scope("party:Player-1234-Alice:Player-1234-Alice,Player-1234-Bob"));
        assert!(!is_party_scope("party:Player-1403-0A1B2C3D:Player-1403-0A1B2C3D"));
        assert!(!is_party_scope("party:Player-1:Player-2"));
        assert!(!is_party_scope("party:Player-1403-0A1B2C3D:Player-1403-0A1B2C3D,Player-1403-0B2C3D4E,evil"));
        assert!(!is_party_scope("3:123"));
        assert!(valid_scope("3:123") && valid_scope("party:Player-1-A:Player-1-A,Player-1-B"));
    }

    #[test]
    fn truncated_utf8_tail_is_trimmed() {
        assert_eq!(utf8(b"caf\xC3").unwrap(), "caf");
        assert!(utf8(b"ca\xC3f").is_err());
    }
}
