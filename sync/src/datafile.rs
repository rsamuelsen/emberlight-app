//! The `Emberlight_Data` addon: a data-only folder the sync tool owns and rewrites.
//!
//! WoW loads addon files at login and `/reload` and never writes them back, so updating this
//! folder cannot race the game's own SavedVariables save.

use crate::lua::{self, Value, field};
use crate::records::{self, Notice, Removed, Reply, Skipped};
use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

pub const ADDON_DIR: &str = "Emberlight_Data";
pub const FORMAT: i64 = 1;
const GLOBAL: &str = "EmberlightArchive";

/// Lua 5.1 string literal. Every byte that could end the literal or confuse a reader is escaped;
/// UTF-8 passes through unchanged.
pub fn lua_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c as u32 == 0x7f => out.push_str(&format!("\\{:03}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// What the data addon holds: guild records as the server last sent them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Archive {
    pub generated: i64,
    pub notices: Vec<Notice>,
    pub replies: Vec<Reply>,
    /// Notices an officer removed: the addon removes them if it still holds them.
    pub removed: Vec<Removed>,
}

/// One board's records in the data file: notices, replies and removals.
type Board<'a> = (Vec<&'a Notice>, Vec<&'a Reply>, Vec<&'a Removed>);

pub fn render_data(archive: &Archive) -> String {
    let generated = archive.generated;
    let mut scopes: BTreeMap<&str, Board> = BTreeMap::new();
    for n in &archive.notices {
        scopes.entry(&n.scope).or_default().0.push(n);
    }
    for r in &archive.replies {
        scopes.entry(&r.scope).or_default().1.push(r);
    }
    for r in &archive.removed {
        scopes.entry(&r.scope).or_default().2.push(r);
    }
    let mut s = String::new();
    s.push_str("-- Written by the Emberlight sync tool. Replaced on every sync; edits here are lost.\n");
    s.push_str(&format!("{GLOBAL} = {{\n\tformat = {FORMAT},\n\tgenerated = {generated},\n\tscopes = {{\n"));
    for (scope, (list, replies, removed)) in scopes {
        s.push_str(&format!("\t\t[{}] = {{\n\t\t\tnotices = {{\n", lua_string(scope)));
        let mut list = list;
        list.sort_by(|a, b| a.id.cmp(&b.id));
        for n in list {
            s.push_str(&format!("\t\t\t\t[{}] = {{\n", lua_string(&n.id)));
            let fields: [(&str, String); 11] = [
                ("owner", lua_string(&n.owner)),
                ("author", lua_string(&n.author)),
                ("revision", n.revision.to_string()),
                ("created", n.created.to_string()),
                ("expires", n.expires.to_string()),
                ("start", n.start.to_string()),
                ("category", n.category.to_string()),
                ("cancelled", n.cancelled.to_string()),
                ("title", lua_string(&n.title)),
                ("location", lua_string(&n.location)),
                ("body", lua_string(&n.body)),
            ];
            for (k, v) in fields {
                s.push_str(&format!("\t\t\t\t\t{k} = {v},\n"));
            }
            s.push_str("\t\t\t\t},\n");
        }
        s.push_str("\t\t\t},\n");
        if !replies.is_empty() {
            let mut by_notice: BTreeMap<&str, Vec<&Reply>> = BTreeMap::new();
            for r in replies {
                by_notice.entry(&r.notice_id).or_default().push(r);
            }
            s.push_str("\t\t\treplies = {\n");
            for (notice, mut list) in by_notice {
                list.sort_by(|a, b| a.respondent.cmp(&b.respondent));
                s.push_str(&format!("\t\t\t\t[{}] = {{\n", lua_string(notice)));
                for r in list {
                    // A line rides with its answer; an addon from before 0.8.7 ignores the two fields.
                    let line = match (&r.line, r.line_revision) {
                        (Some(text), Some(revision)) => format!(", line = {}, lineRevision = {revision}", lua_string(text)),
                        _ => String::new(),
                    };
                    s.push_str(&format!(
                        "\t\t\t\t\t[{}] = {{ revision = {}, response = {}{line} }},\n",
                        lua_string(&r.respondent),
                        r.revision,
                        lua_string(&r.response)
                    ));
                }
                s.push_str("\t\t\t\t},\n");
            }
            s.push_str("\t\t\t},\n");
        }
        if !removed.is_empty() {
            let mut removed = removed;
            removed.sort();
            s.push_str("\t\t\tremoved = {\n");
            for r in removed {
                s.push_str(&format!("\t\t\t\t[{}] = true,\n", lua_string(&r.id)));
            }
            s.push_str("\t\t\t},\n");
        }
        s.push_str("\t\t},\n");
    }
    s.push_str("\t},\n}\n");
    s
}

/// Read back an archive written by `render_data` (used by tests and to report what is installed).
pub fn read_data(src: &[u8]) -> Result<Archive> {
    let globals = lua::parse(src)?;
    let archive = globals.get(GLOBAL).and_then(Value::as_table).context("no archive in data file")?;
    if field(archive, "format").and_then(Value::as_int) != Some(FORMAT) {
        bail!("unsupported archive format");
    }
    let generated = field(archive, "generated").and_then(Value::as_int).context("missing generated time")?;
    let mut notices = Vec::new();
    let mut replies = Vec::new();
    let mut removed = Vec::new();
    for (scope_key, scope) in field(archive, "scopes").and_then(Value::as_table).context("missing scopes")? {
        let lua::Key::Str(scope_name) = scope_key else { bail!("scope key is not a string") };
        let scope_name = String::from_utf8(scope_name.clone())?;
        let list = scope.as_table().and_then(|s| field(s, "notices")).and_then(Value::as_table).context("missing notices")?;
        for (id_key, entry) in list {
            let lua::Key::Str(id) = id_key else { bail!("notice key is not a string") };
            let t = entry.as_table().context("notice is not a table")?;
            let s = |k: &str| -> Result<String> {
                Ok(String::from_utf8(field(t, k).and_then(Value::as_bytes).with_context(|| format!("missing {k}"))?.to_vec())?)
            };
            let i = |k: &str| field(t, k).and_then(Value::as_int).with_context(|| format!("missing {k}"));
            notices.push(Notice {
                scope: scope_name.clone(),
                id: String::from_utf8(id.clone())?,
                owner: s("owner")?,
                author: s("author")?,
                revision: i("revision")?,
                created: i("created")?,
                expires: i("expires")?,
                start: i("start")?,
                category: i("category")?,
                cancelled: field(t, "cancelled").and_then(Value::as_bool).context("missing cancelled")?,
                title: s("title")?,
                location: s("location")?,
                body: s("body")?,
            });
        }
        let reply_table = scope.as_table().and_then(|s| field(s, "replies")).and_then(Value::as_table);
        for (notice_key, answers) in reply_table.into_iter().flatten() {
            let lua::Key::Str(notice_id) = notice_key else { bail!("reply key is not a string") };
            for (who, answer) in answers.as_table().context("replies are not a table")? {
                let lua::Key::Str(respondent) = who else { bail!("respondent is not a string") };
                let t = answer.as_table().context("reply is not a table")?;
                replies.push(Reply {
                    scope: scope_name.clone(),
                    notice_id: String::from_utf8(notice_id.clone())?,
                    respondent: String::from_utf8(respondent.clone())?,
                    revision: field(t, "revision").and_then(Value::as_int).context("missing revision")?,
                    response: String::from_utf8(field(t, "response").and_then(Value::as_bytes).context("missing response")?.to_vec())?,
                    line: field(t, "line").and_then(Value::as_bytes).map(|b| String::from_utf8(b.to_vec())).transpose()?,
                    line_revision: field(t, "lineRevision").and_then(Value::as_int),
                });
            }
        }
        let removed_table = scope.as_table().and_then(|s| field(s, "removed")).and_then(Value::as_table);
        for id_key in removed_table.into_iter().flat_map(|t| t.keys()) {
            let lua::Key::Str(id) = id_key else { bail!("removed key is not a string") };
            removed.push(Removed { scope: scope_name.clone(), id: String::from_utf8(id.clone())? });
        }
    }
    removed.sort();
    Ok(Archive { generated, notices, replies, removed })
}

/// The `## Interface:` value of the installed Emberlight addon, so the data addon is never
/// flagged out of date when Emberlight itself is not.
pub fn read_interface(addons: &Path) -> Result<String> {
    let toc_path = addons.join("Emberlight").join("Emberlight.toc");
    let toc = fs::read_to_string(&toc_path).with_context(|| format!("Emberlight is not installed at {}", toc_path.display()))?;
    let value = toc
        .lines()
        .find_map(|l| l.strip_prefix("## Interface:"))
        .map(str::trim)
        .context("Emberlight.toc has no Interface line")?;
    if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit() || b == b',' || b == b' ') {
        bail!("Emberlight.toc has an unexpected Interface value");
    }
    Ok(value.to_owned())
}

pub fn render_toc(interface: &str) -> String {
    format!(
        "## Interface: {interface}\n## Title: Emberlight Data\n## Notes: Guild records downloaded by the Emberlight sync tool.\n## Author: Emberlight\n## Version: {FORMAT}\nData.lua\n"
    )
}

fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    if fs::read(path).is_ok_and(|old| old == contents) {
        return Ok(());
    }
    // A temporary name of its own (process and a counter), so two syncs at once (the launcher
    // and the command-line tool) never write into the same temporary file. `create_new` refuses
    // to reuse a leftover.
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let name = path.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.{}.{n}.tmp", std::process::id()));
    let written = (|| -> Result<()> {
        let mut f = fs::OpenOptions::new().write(true).create_new(true).open(&tmp).with_context(|| format!("cannot write {}", tmp.display()))?;
        f.write_all(contents)?;
        f.sync_all()?;
        fs::rename(&tmp, path).with_context(|| format!("cannot replace {}", path.display()))
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written
}

pub struct WriteReport {
    pub dir: PathBuf,
    pub written: usize,
    pub rejected: Vec<Skipped>,
}

/// Validate and install records into `<addons>/Emberlight_Data`. Callers must first confirm the
/// game is not running.
pub fn write_data_addon(addons: &Path, archive: &Archive) -> Result<WriteReport> {
    let interface = read_interface(addons)?;
    let mut accepted = Vec::new();
    let mut rejected = Vec::new();
    let mut seen = BTreeMap::new();
    for n in &archive.notices {
        match n.validate() {
            Err(reason) => rejected.push(Skipped { scope: n.scope.clone(), id: n.id.clone(), reason }),
            Ok(()) => {
                if seen.insert((n.scope.clone(), n.id.clone()), ()).is_some() {
                    rejected.push(Skipped { scope: n.scope.clone(), id: n.id.clone(), reason: "duplicate id".into() });
                } else {
                    accepted.push(n.clone());
                }
            }
        }
    }
    // Replies only travel with a notice that is in the file; the addon checks them again.
    let mut answered = BTreeMap::new();
    let mut replies = Vec::new();
    for r in &archive.replies {
        let known = accepted.iter().any(|n: &Notice| n.scope == r.scope && n.id == r.notice_id);
        let result = if !known { Err("its notice is not in this download".to_string()) } else { r.validate() };
        match result {
            Ok(()) if answered.insert((r.scope.clone(), r.notice_id.clone(), r.respondent.clone()), ()).is_none() => replies.push(r.clone()),
            Ok(()) => {}
            Err(reason) => rejected.push(Skipped { scope: r.scope.clone(), id: format!("{} reply by {}", r.notice_id, r.respondent), reason }),
        }
    }
    // A removal names a notice id only; the addon applies it to a notice it already holds.
    let mut removed: Vec<Removed> = Vec::new();
    for r in &archive.removed {
        if !records::valid_scope(&r.scope) || records::notice_owner(&r.id).is_none() {
            rejected.push(Skipped { scope: r.scope.clone(), id: r.id.clone(), reason: "removal is not valid".into() });
        } else if !removed.contains(r) {
            removed.push(r.clone());
        }
    }
    removed.sort();
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let out = Archive { generated: archive.generated, notices: accepted, replies, removed };
    write_atomic(&dir.join("Data.lua"), render_data(&out).as_bytes())?;
    write_atomic(&dir.join(format!("{ADDON_DIR}.toc")), render_toc(&interface).as_bytes())?;
    Ok(WriteReport { dir, written: out.notices.len(), rejected })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_lines_round_trip_through_the_data_file() {
        let notice = crate::records::Notice {
            scope: "3:123".into(), id: "alice-testrealm:1800000000000".into(), owner: "alice-testrealm".into(), author: "Alice-TestRealm".into(),
            revision: 1, created: 1_800_000_000, expires: 1_800_007_200, start: 1_800_000_000, category: 1, cancelled: false,
            title: "Title".into(), location: String::new(), body: "Body".into(),
        };
        let with_line = Reply {
            scope: "3:123".into(), notice_id: notice.id.clone(), respondent: "bob-testrealm".into(), revision: 5,
            response: "I will join".into(), line: Some("as the \"caravan\" guard".into()), line_revision: Some(8),
        };
        let without = Reply { respondent: "carol-testrealm".into(), line: None, line_revision: None, ..with_line.clone() };
        let archive = Archive { generated: 1, notices: vec![notice], replies: vec![with_line.clone(), without.clone()], removed: vec![] };
        let back = read_data(render_data(&archive).as_bytes()).unwrap();
        assert_eq!(back.replies, vec![with_line, without]);
    }

    #[test]
    fn string_literal_round_trips_through_parser() {
        let tricky = "q\"uote\\ back\nline\r\t tab \u{1}\u{7f} ]] ]==] é 火";
        let src = format!("X = {}", lua_string(tricky));
        let parsed = lua::parse(src.as_bytes()).unwrap();
        assert_eq!(parsed["X"].as_bytes().unwrap(), tricky.as_bytes());
        assert!(!src.contains('\n'));
    }

    #[test]
    fn toc_interface_is_checked() {
        let dir = tempfile::tempdir().unwrap();
        let addon = dir.path().join("Emberlight");
        fs::create_dir_all(&addon).unwrap();
        fs::write(addon.join("Emberlight.toc"), "## Interface: 120100\n## Title: Emberlight\n").unwrap();
        assert_eq!(read_interface(dir.path()).unwrap(), "120100");
        fs::write(addon.join("Emberlight.toc"), "## Interface: 120100\n## LoadOnDemand: 1\n").unwrap();
        assert_eq!(read_interface(dir.path()).unwrap(), "120100");
        fs::write(addon.join("Emberlight.toc"), "## Interface: 1\nData.lua\n## X\n").unwrap();
        assert_eq!(read_interface(dir.path()).unwrap(), "1");
        fs::write(addon.join("Emberlight.toc"), "## Interface: 1\r\n").unwrap();
        assert_eq!(read_interface(dir.path()).unwrap(), "1");
        fs::write(addon.join("Emberlight.toc"), "## Interface: 1 # x\n").unwrap();
        assert!(read_interface(dir.path()).is_err());
    }
}
