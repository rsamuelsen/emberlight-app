//! The `Emberlight_Data` addon: a data-only folder the sync tool owns and rewrites.
//!
//! WoW loads addon files at login and `/reload` and never writes them back, so updating this
//! folder cannot race the game's own SavedVariables save.

use crate::api::{BankGame, CraftDirectory, CraftRequests, RosterCheck, WayfarersGame};
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
/// The officers' roster check, in a file of its own beside Data.lua (`Roster.lua`, global
/// `EmberlightRoster`). Addons before 0.8.12 never read it.
pub const ROSTER_FILE: &str = "Roster.lua";
const ROSTER_GLOBAL: &str = "EmberlightRoster";
pub const ROSTER_FORMAT: i64 = 1;
/// Crafting requests this member can make or asked for (`Crafting.lua`, global `EmberlightCrafting`),
/// from `GET /v1/professions/requests/game`. Addons before 0.8.13 never read it.
pub const CRAFTING_FILE: &str = "Crafting.lua";
const CRAFTING_GLOBAL: &str = "EmberlightCrafting";
pub const CRAFTING_FORMAT: i64 = 1;
const CRAFTING_REQUESTS: usize = 100;
/// The guild's newest published addon version, as the Companion's last update check saw it
/// (`Latest.lua`, global `EmberlightLatest`), so the addon can say it is out of date even when no
/// guildmate is online. Addons before 0.9.0 never read it.
pub const LATEST_FILE: &str = "Latest.lua";
const LATEST_GLOBAL: &str = "EmberlightLatest";
pub const LATEST_FORMAT: i64 = 1;
/// The guild bank as the website last saw it (`Bank.lua`, global `EmberlightBank`), from
/// `GET /v1/bank/game`, for the addon's bank panel and item tooltips. Addons before 1.0.1 never read it.
pub const BANK_FILE: &str = "Bank.lua";
const BANK_GLOBAL: &str = "EmberlightBank";
pub const BANK_FORMAT: i64 = 1;
const BANK_ITEMS: usize = 12 * 98;
/// The officers' Wayfarers list (`Wayfarers.lua`, global `EmberlightWayfarers`), from
/// `GET /v1/officer/wayfarers/game`; officers only. Addons before 1.0.1 never read it.
pub const WAYFARERS_FILE: &str = "Wayfarers.lua";
const WAYFARERS_GLOBAL: &str = "EmberlightWayfarers";
pub const WAYFARERS_FORMAT: i64 = 1;
const WAYFARERS: usize = 500;
/// Limits that keep a damaged reply from writing a huge file; far above any real guild.
const ROSTER_MEMBERS: usize = 2000;
const ROSTER_CHARACTERS: usize = 50;

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
            // A Story Event (addon 0.9.3); an older addon ignores the extra field.
            if n.story && n.category == 4 {
                s.push_str("\t\t\t\t\tstory = true,\n");
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

/// A name or rank for the roster file: ordinary text of a sensible length, nothing else.
fn roster_text(s: &str, max: usize) -> bool {
    !s.is_empty() && s.chars().count() <= max && !s.chars().any(|c| c.is_control() || c == '|')
}

/// A character's key as the addon makes it from an in-game name (`C.Canonical`, before the realm):
/// lower case, "_" for a space, no "-".
fn roster_key(s: &str) -> bool {
    roster_text(s, 120) && !s.contains('-') && !s.chars().any(char::is_whitespace) && !s.chars().any(|c| c.is_ascii_uppercase())
}

/// The roster file. `None` (not an officer) writes a file with no list, so a list written for an
/// officer earlier never stays on a computer whose member is not one now.
pub fn render_roster(roster: Option<&RosterCheck>) -> String {
    let mut s = String::from("-- Written by the Emberlight sync tool. Replaced on every sync; edits here are lost.\n");
    let Some(roster) = roster else {
        s.push_str("-- Only officers get the member list for the roster check.\n");
        return s;
    };
    s.push_str("-- The guild's members for the officers' roster check. Keep this computer's files private.\n");
    s.push_str(&format!(
        "{ROSTER_GLOBAL} = {{\n\tformat = {ROSTER_FORMAT},\n\tgenerated = {},\n\tfresh = {},\n\tmembers = {{\n",
        roster.generated, roster.fresh
    ));
    for m in roster.members.iter().take(ROSTER_MEMBERS) {
        let characters: Vec<_> = m.characters.iter().filter(|c| roster_text(&c.name, 60) && roster_key(&c.key)).take(ROSTER_CHARACTERS).collect();
        if characters.is_empty() {
            continue;
        }
        let rank = |v: &Option<String>| v.as_deref().filter(|r| roster_text(r, 40)).map_or("nil".to_owned(), lua_string);
        s.push_str(&format!(
            "\t\t{{ rank = {}, inGameRank = {}, altRank = {}, characters = {{\n",
            rank(&m.rank),
            rank(&m.in_game_rank),
            rank(&m.alt_rank)
        ));
        for c in characters {
            s.push_str(&format!("\t\t\t{{ name = {}, key = {}, main = {} }},\n", lua_string(&c.name), lua_string(&c.key), c.main));
        }
        s.push_str("\t\t} },\n");
    }
    s.push_str("\t},\n}\n");
    s
}

/// The crafting requests file. `None` (an older server, or not signed in) writes a file with no list.
pub fn render_crafting(requests: Option<&CraftRequests>) -> String {
    let mut s = String::from("-- Written by the Emberlight sync tool. Replaced on every sync; edits here are lost.\n");
    let Some(list) = requests else {
        s.push_str("-- No crafting requests were downloaded.\n");
        return s;
    };
    s.push_str(&format!("{CRAFTING_GLOBAL} = {{\n\tformat = {CRAFTING_FORMAT},\n\tgenerated = {},\n\trequests = {{\n", list.generated));
    let text = |v: &str, max: usize| roster_text(v, max);
    for r in list.requests.iter().take(CRAFTING_REQUESTS) {
        if !text(&r.recipe, 100) || !text(&r.for_character, 60) || !text(&r.skill, 20) || !(1..=20).contains(&r.quantity) || !["open", "claimed"].contains(&r.status.as_str()) {
            continue;
        }
        let note: String = r.note.chars().filter(|c| !c.is_control() && *c != '|').take(300).collect();
        let crafter = r.crafter.as_deref().filter(|c| text(c, 60)).map_or("nil".to_owned(), lua_string);
        let can: Vec<String> = r.can_make_with.iter().filter(|c| text(c, 60)).take(10).map(|c| lua_string(c)).collect();
        s.push_str(&format!(
            "\t\t{{ id = {}, skill = {}, recipe = {}, quantity = {}, forCharacter = {}, note = {}, status = {}, crafter = {}, mine = {}, takenByMe = {}, canMakeWith = {{ {} }}, created = {} }},\n",
            r.id, lua_string(&r.skill), lua_string(&r.recipe), r.quantity, lua_string(&r.for_character), lua_string(&note), lua_string(&r.status),
            crafter, r.mine, r.taken_by_me, can.join(", "), r.created_at
        ));
    }
    s.push_str("\t},\n}\n");
    s
}

fn render_directory(out: &mut String, directory: &CraftDirectory, generated: i64) {
    let characters: BTreeMap<_, _> = directory.characters.iter().take(5000)
        .filter(|c| c.id > 0 && roster_text(&c.name, 60))
        .map(|c| (c.id, &c.name)).collect();
    out.push_str(&format!("EmberlightDirectory = {{ format = 1, generated = {generated}, names = {{\n"));
    for (id, name) in &characters {
        out.push_str(&format!("[{id}] = {},\n", lua_string(name)));
    }
    out.push_str("}, recipes = {\n");
    for r in directory.recipes.iter().take(20000) {
        if !roster_text(&r.name, 100) || !roster_text(&r.skill, 24) { continue; }
        let crafters: Vec<_> = r.crafters.iter().take(5000).filter(|id| characters.contains_key(*id)).map(i64::to_string).collect();
        if crafters.is_empty() { continue; }
        let aliases = r.other_names.iter().take(16).filter(|s| roster_text(s, 100)).cloned().collect::<Vec<_>>().join(" / ");
        let mats = r.reagents.iter().take(32).filter(|m| roster_text(&m.name, 100) && (1..=100).contains(&m.count))
            .map(|m| format!("{} × {}", m.count, m.name)).collect::<Vec<_>>().join(", ");
        out.push_str(&format!("{{ name = {}, skill = {}, aliases = {}, materials = {}, crafters = {{ {} }} }},\n",
            lua_string(&r.name), lua_string(&r.skill), lua_string(&aliases), lua_string(&mats), crafters.join(", ")));
    }
    out.push_str("} }\n");
}

/// Write `<addons>/Emberlight_Data/Crafting.lua`. Callers must first confirm the game is not running.
pub fn write_crafting(addons: &Path, requests: Option<&CraftRequests>, directory: Option<&CraftDirectory>, generated: i64) -> Result<()> {
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    let mut content = render_crafting(requests);
    if let Some(directory) = directory {
        render_directory(&mut content, directory, generated);
    }
    write_atomic(&dir.join(CRAFTING_FILE), content.as_bytes())
}

/// Text for a Lua string: no control characters but line breaks (Info text keeps them), no `|`
/// (the game's escape character), at most `max` characters.
fn game_text(v: &str, max: usize, lines: bool) -> String {
    v.chars().filter(|c| (lines && *c == '\n') || (!c.is_control() && *c != '|')).take(max).collect()
}

/// The guild bank file. `None` (an older server, or not signed in) writes a file with no bank.
pub fn render_bank(bank: Option<&BankGame>) -> String {
    let mut s = String::from("-- Written by the Emberlight sync tool. Replaced on every sync; edits here are lost.\n");
    let Some(bank) = bank else {
        s.push_str("-- No guild bank was downloaded.\n");
        return s;
    };
    let opt = |v: Option<i64>| v.map_or("nil".to_owned(), |n| n.to_string());
    s.push_str(&format!("{BANK_GLOBAL} = {{\n\tformat = {BANK_FORMAT},\n\tgenerated = {},\n\treadAt = {},\n\tcopper = {},\n\ttabs = {{\n", bank.generated, opt(bank.read_at), opt(bank.copper)));
    for t in bank.tabs.iter().filter(|t| (1..=12).contains(&t.tab)).take(12) {
        s.push_str(&format!("\t\t{{ tab = {}, name = {}, text = {}, readAt = {} }},\n", t.tab, lua_string(&game_text(&t.name, 40, false)), lua_string(&game_text(&t.text, 2047, true)), opt(t.read_at)));
    }
    s.push_str("\t},\n\titems = {\n");
    for i in bank.items.iter().filter(|i| i.item_id > 0 && i.count > 0).take(BANK_ITEMS) {
        let tabs: Vec<String> = i.tabs.iter().take(12).map(|t| lua_string(&game_text(t, 40, false))).collect();
        s.push_str(&format!("\t\t{{ id = {}, name = {}, count = {}, quality = {}, tabs = {{ {} }} }},\n", i.item_id, lua_string(&game_text(&i.name, 100, false)), i.count, opt(i.quality), tabs.join(", ")));
    }
    s.push_str("\t},\n\twanted = {\n");
    for w in bank.wanted.iter().filter(|w| w.target > 0).take(60) {
        s.push_str(&format!("\t\t{{ id = {}, name = {}, target = {}, have = {} }},\n", opt(w.item_id), lua_string(&game_text(&w.name, 100, false)), w.target, w.have.max(0)));
    }
    s.push_str(&format!("\t}},\n\trequestsOpen = {},\n\trequests = {{\n", bank.requests_open));
    const STATUSES: [&str; 3] = ["open", "filled", "declined"];
    for r in bank.requests.iter().filter(|r| r.id > 0 && r.count > 0 && STATUSES.contains(&r.status.as_str())).take(100) {
        let txt = |v: Option<&str>, max: usize| v.map_or("nil".to_owned(), |t| lua_string(&game_text(t, max, false)));
        s.push_str(&format!(
            "\t\t{{ id = {}, character = {}, itemId = {}, item = {}, count = {}, note = {}, status = {}, answer = {}, decidedBy = {}, createdAt = {}, mine = {} }},\n",
            r.id, lua_string(&game_text(&r.character, 60, false)), opt(r.item_id), lua_string(&game_text(&r.item, 100, false)), r.count,
            lua_string(&game_text(&r.note, 200, false)), lua_string(&r.status), txt(r.answer.as_deref(), 200), txt(r.decided_by.as_deref(), 60), r.created_at, r.mine
        ));
    }
    s.push_str("\t},\n}\n");
    s
}

/// The officers' Wayfarers file. `None` (not an officer, or an older server) writes no list.
pub fn render_wayfarers(list: Option<&WayfarersGame>) -> String {
    let mut s = String::from("-- Written by the Emberlight sync tool. Replaced on every sync; edits here are lost.\n");
    let Some(list) = list else {
        s.push_str("-- Only officers get the Wayfarers list.\n");
        return s;
    };
    s.push_str("-- The officers' Wayfarers list. Keep this computer's files private.\n");
    let opt = |v: Option<i64>| v.map_or("nil".to_owned(), |n| n.to_string());
    let txt = |v: Option<&str>, max: usize| v.map_or("nil".to_owned(), |t| lua_string(&game_text(t, max, false)));
    const GROUPS: [&str; 6] = ["due", "hello", "quiet", "character", "away", "fine"];
    s.push_str(&format!("{WAYFARERS_GLOBAL} = {{\n\tformat = {WAYFARERS_FORMAT},\n\tgenerated = {},\n\tlist = {{\n", list.generated));
    for w in list.wayfarers.iter().filter(|w| GROUPS.contains(&w.group.as_str())).take(WAYFARERS) {
        let characters: Vec<String> = w.characters.iter().filter(|c| roster_text(&c.name, 60) && roster_key(&c.key)).take(20)
            .map(|c| format!("{{ name = {}, key = {}, main = {} }}", lua_string(&c.name), lua_string(&c.key), c.main)).collect();
        let follow = w.last_follow_up.as_ref().map_or("nil".to_owned(), |f| format!("{{ label = {}, by = {}, at = {} }}", txt(f.label.as_deref(), 20), lua_string(&game_text(&f.by, 60, false)), f.at));
        let next = w.next_follow_up.as_deref().filter(|d| d.len() == 10 && d.bytes().all(|b| b.is_ascii_digit() || b == b'-'));
        s.push_str(&format!(
            "\t\t{{ name = {}, main = {}, days = {}, group = {}, quietDays = {}, nextFollowUp = {}, followUpBy = {}, lastFollowUp = {}, mentor = {}, away = {}, lastSeen = {}, characters = {{ {} }} }},\n",
            lua_string(&game_text(&w.name, 100, false)), txt(w.main.as_deref(), 60), opt(w.days), lua_string(&w.group), opt(w.quiet_days),
            txt(next, 10), txt(w.follow_up_by.as_deref(), 100), follow, txt(w.mentor.as_deref(), 100), opt(w.away), opt(w.last_seen), characters.join(", ")
        ));
    }
    s.push_str("\t},\n}\n");
    s
}

/// Write `<addons>/Emberlight_Data/Bank.lua`. Callers must first confirm the game is not running.
pub fn write_bank(addons: &Path, bank: Option<&BankGame>) -> Result<()> {
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    write_atomic(&dir.join(BANK_FILE), render_bank(bank).as_bytes())
}

/// Write `<addons>/Emberlight_Data/Wayfarers.lua`. Callers must first confirm the game is not running.
pub fn write_wayfarers(addons: &Path, list: Option<&WayfarersGame>) -> Result<()> {
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    write_atomic(&dir.join(WAYFARERS_FILE), render_wayfarers(list).as_bytes())
}

/// Write `<addons>/Emberlight_Data/Roster.lua`. Callers must first confirm the game is not running.
pub fn write_roster(addons: &Path, roster: Option<&RosterCheck>) -> Result<()> {
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    write_atomic(&dir.join(ROSTER_FILE), render_roster(roster).as_bytes())
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
                story: field(t, "story").and_then(Value::as_bool).unwrap_or(false),
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
        "## Interface: {interface}\n## Title: Emberlight Data\n## Notes: Guild records downloaded by the Emberlight sync tool.\n## Author: Emberlight\n## Version: {FORMAT}\nData.lua\nRoster.lua\nCrafting.lua\nLatest.lua\nBank.lua\nWayfarers.lua\n"
    )
}

/// A plain version number ("0.9.1"), nothing else.
fn plain_version(v: &str) -> bool {
    !v.is_empty() && v.len() <= 16 && v.bytes().all(|b| b.is_ascii_digit() || b == b'.') && v.split('.').count() == 3 && v.split('.').all(|p| !p.is_empty())
}

pub fn render_latest(version: Option<&str>, checked: i64) -> String {
    match version.filter(|v| plain_version(v)) {
        Some(v) => format!("{LATEST_GLOBAL} = {{\n\tformat = {LATEST_FORMAT},\n\tchecked = {checked},\n\taddon = {},\n}}\n", lua_string(v)),
        None => format!("{LATEST_GLOBAL} = {{\n\tformat = {LATEST_FORMAT},\n\tchecked = {checked},\n}}\n"),
    }
}

/// Write `<addons>/Emberlight_Data/Latest.lua`. Callers must first confirm the game is not running.
pub fn write_latest(addons: &Path, version: Option<&str>, checked: i64) -> Result<()> {
    let dir = addons.join(ADDON_DIR);
    fs::create_dir_all(&dir).with_context(|| format!("cannot create {}", dir.display()))?;
    write_atomic(&dir.join(LATEST_FILE), render_latest(version, checked).as_bytes())
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
    /// Members in the officers' roster check, when one was written.
    pub roster: Option<usize>,
    /// Why the roster check could not be downloaded (the one from the last sync stays).
    pub roster_problem: Option<String>,
    pub crafting_problem: Option<String>,
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
    // The TOC names Roster.lua: make sure there is one, without a list, until a sync writes it.
    let roster = dir.join(ROSTER_FILE);
    if !roster.exists() {
        write_atomic(&roster, render_roster(None).as_bytes())?;
    }
    let crafting = dir.join(CRAFTING_FILE);
    if !crafting.exists() {
        write_atomic(&crafting, render_crafting(None).as_bytes())?;
    }
    let latest = dir.join(LATEST_FILE);
    if !latest.exists() {
        write_atomic(&latest, render_latest(None, 0).as_bytes())?;
    }
    let bank = dir.join(BANK_FILE);
    if !bank.exists() {
        write_atomic(&bank, render_bank(None).as_bytes())?;
    }
    let wayfarers = dir.join(WAYFARERS_FILE);
    if !wayfarers.exists() {
        write_atomic(&wayfarers, render_wayfarers(None).as_bytes())?;
    }
    write_atomic(&dir.join(format!("{ADDON_DIR}.toc")), render_toc(&interface).as_bytes())?;
    Ok(WriteReport { dir, written: out.notices.len(), rejected, roster: None, roster_problem: None, crafting_problem: None })
}

#[cfg(test)]
mod tests {
    #[test]
    fn bank_and_wayfarers_files_are_written_for_the_addon() {
        use crate::api::{BankGame, BankGameItem, BankGameRequest, BankGameTab, BankGameWanted, RosterCharacter, WayfarerGame, WayfarersGame};
        let bank = BankGame {
            generated: 1800000000, read_at: Some(1799999000), copper: Some(123),
            tabs: vec![BankGameTab { tab: 1, name: "Cloth|r".into(), text: "Line one\nLine \"two\"".into(), read_at: Some(1799999000) }],
            items: vec![BankGameItem { item_id: 2589, name: "Linen Cloth".into(), count: 24, quality: Some(1), tabs: vec!["Cloth".into()] }],
            wanted: vec![BankGameWanted { item_id: None, name: "Wool Cloth".into(), target: 40, have: 2 }],
            requests_open: true,
            requests: vec![
                BankGameRequest { id: 7, character: "Alice Example".into(), item_id: Some(2589), item: "Linen Cloth".into(), count: 5, note: "For |cffbandages".into(), status: "open".into(), answer: None, decided_by: None, created_at: 1799999500, mine: true },
                BankGameRequest { id: 8, character: "Bob".into(), item_id: None, item: "Odd".into(), count: 1, note: String::new(), status: "withdrawn".into(), answer: None, decided_by: None, created_at: 1799999600, mine: false },
            ],
        };
        let text = render_bank(Some(&bank));
        let parsed = crate::lua::parse(text.as_bytes()).unwrap();
        let t = parsed.get(BANK_GLOBAL).and_then(Value::as_table).unwrap();
        assert_eq!(field(t, "copper").and_then(Value::as_int), Some(123));
        assert!(text.contains("name = \"Clothr\""), "no escape characters reach the game");
        assert!(text.contains("Line one\\nLine \\\"two\\\""));
        assert!(text.contains("{ id = 2589, name = \"Linen Cloth\", count = 24, quality = 1, tabs = { \"Cloth\" } }"));
        assert!(text.contains("{ id = nil, name = \"Wool Cloth\", target = 40, have = 2 }"));
        assert!(text.contains("requestsOpen = true"));
        assert!(text.contains("{ id = 7, character = \"Alice Example\", itemId = 2589, item = \"Linen Cloth\", count = 5, note = \"For cffbandages\", status = \"open\", answer = nil, decidedBy = nil, createdAt = 1799999500, mine = true }"));
        assert!(!text.contains("withdrawn"), "only open and answered requests reach the game");
        assert!(!render_bank(None).contains(BANK_GLOBAL));

        let list = WayfarersGame { generated: 1800000000, wayfarers: vec![
            WayfarerGame { name: "Alice".into(), main: Some("Alice Example".into()), days: Some(5), group: "hello".into(), quiet_days: Some(0), next_follow_up: Some("2026-11-30".into()), follow_up_by: None, last_follow_up: None, mentor: None, away: None, last_seen: Some(1799990000), characters: vec![RosterCharacter { name: "Alice Example".into(), key: "alice_example".into(), main: true }] },
            WayfarerGame { name: "Odd".into(), main: None, days: None, group: "unknown".into(), quiet_days: None, next_follow_up: None, follow_up_by: None, last_follow_up: None, mentor: None, away: None, last_seen: None, characters: vec![] },
        ] };
        let text = render_wayfarers(Some(&list));
        let parsed = crate::lua::parse(text.as_bytes()).unwrap();
        let w = parsed.get(WAYFARERS_GLOBAL).and_then(Value::as_table).and_then(|t| field(t, "list")).and_then(Value::as_table).unwrap();
        assert_eq!(w.len(), 1, "an unknown group is left out");
        assert!(text.contains("nextFollowUp = \"2026-11-30\""));
        assert!(text.contains("{ name = \"Alice Example\", key = \"alice_example\", main = true }"));
        assert!(!render_wayfarers(None).contains(WAYFARERS_GLOBAL));
    }

    use super::*;

    #[test]
    fn story_events_are_marked_in_the_data_file() {
        let story = crate::records::Notice {
            scope: "3:123".into(), id: "alice-testrealm:1800000000000".into(), owner: "alice-testrealm".into(), author: "Alice-TestRealm".into(),
            revision: 1, created: 1_800_000_000, expires: 1_800_007_200, start: 1_800_000_000, category: 4, cancelled: false,
            title: "Title".into(), location: String::new(), body: "Body".into(), story: true,
        };
        let gathering = crate::records::Notice { id: "alice-testrealm:1800000000001".into(), story: false, ..story.clone() };
        let archive = Archive { generated: 1, notices: vec![story.clone(), gathering.clone()], replies: vec![], removed: vec![] };
        let text = render_data(&archive);
        assert_eq!(text.matches("story = true").count(), 1);
        let back = read_data(text.as_bytes()).unwrap();
        assert_eq!(back.notices, vec![story, gathering]);
        // The server's download names it; an upload never carries it.
        let parsed: crate::records::Notice = serde_json::from_str(r#"{"scope":"3:123","id":"a-b:1","owner":"a-b","author":"A-B","revision":1,"created":1,"expires":2,"start":1,"category":4,"cancelled":false,"title":"t","location":"","body":"b","story":true}"#).unwrap();
        assert!(parsed.story);
        assert!(!serde_json::to_string(&crate::records::Notice { story: false, ..parsed }).unwrap().contains("story"));
    }

    #[test]
    fn reply_lines_round_trip_through_the_data_file() {
        let notice = crate::records::Notice {
            scope: "3:123".into(), id: "alice-testrealm:1800000000000".into(), owner: "alice-testrealm".into(), author: "Alice-TestRealm".into(),
            revision: 1, created: 1_800_000_000, expires: 1_800_007_200, start: 1_800_000_000, category: 1, cancelled: false,
            title: "Title".into(), location: String::new(), body: "Body".into(), story: false,
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
    fn directory_keeps_visible_crafters_and_escapes_their_recipe_text() {
        let directory: CraftDirectory = serde_json::from_str(r#"{
            "characters":[{"id":2,"name":"Sam Smith","owner":"private metadata"}],
            "recipes":[{"name":"Copper belt","skill":"Blacksmithing","otherNames":["Kupfer"],"crafters":[2,9],
                        "reagents":[{"count":6,"name":"Copper Bar"}]},
                       {"name":"Private recipe","skill":"Cooking","crafters":[9],"reagents":[]}]
        }"#).unwrap();
        let mut out = String::new();
        render_directory(&mut out, &directory, 123);
        assert!(lua::parse(out.as_bytes()).unwrap().contains_key("EmberlightDirectory"));
        assert!(out.contains("6 × Copper Bar") && out.contains("Kupfer") && out.contains("crafters = { 2 }"));
        assert!(!out.contains("Private recipe") && !out.contains("private metadata"));
    }

    #[test]
    fn crafting_file_holds_only_valid_requests() {
        use crate::api::{CraftRequest, CraftRequests};
        let good = CraftRequest { id: 7, skill: "Blacksmithing".into(), recipe: "Copper Chain Belt".into(), quantity: 2, for_character: "Ann Example".into(), note: "I bring \"bars\"|x".into(), status: "open".into(), crafter: None, mine: false, taken_by_me: false, can_make_with: vec!["Sam Example".into()], created_at: 1_800_000_000 };
        let bad = CraftRequest { quantity: 99, ..good.clone() };
        let text = render_crafting(Some(&CraftRequests { generated: 1_800_000_100, requests: vec![good, bad] }));
        let globals = lua::parse(text.as_bytes()).unwrap();
        let list = globals.get("EmberlightCrafting").and_then(Value::as_table).and_then(|t| field(t, "requests")).and_then(Value::as_table).unwrap();
        assert_eq!(list.len(), 1);
        assert!(text.contains(r#"note = "I bring \"bars\"x""#));
        assert!(!render_crafting(None).contains("EmberlightCrafting ="));
    }

    #[test]
    fn roster_file_holds_only_valid_entries_and_nothing_for_non_officers() {
        use crate::api::{RosterCharacter, RosterMember};
        let ch = |name: &str, key: &str, main: bool| RosterCharacter { name: name.into(), key: key.into(), main };
        let roster = RosterCheck {
            generated: 1_800_000_000,
            fresh: true,
            checked_at: Some(1),
            members: vec![
                RosterMember { rank: Some("kindled".into()), in_game_rank: Some("Ember".into()), alt_rank: Some("Alt".into()), characters: vec![ch("Alice \"Q\" Example", "alice_\"q\"_example", true), ch("Bad", "Bad-Realm", false), ch("Bob Example", "bob_example", false)] },
                RosterMember { rank: None, in_game_rank: None, alt_rank: None, characters: vec![ch("Carol|Example", "carol_example", false)] },
                RosterMember { rank: None, in_game_rank: None, alt_rank: None, characters: vec![ch("Dan Example", "dan_example", false)] },
            ],
        };
        let text = render_roster(Some(&roster));
        let parsed = lua::parse(text.as_bytes()).unwrap();
        let list = parsed["EmberlightRoster"].as_table().unwrap();
        assert_eq!(field(list, "generated").and_then(Value::as_int), Some(1_800_000_000));
        let members = field(list, "members").and_then(Value::as_table).unwrap();
        assert_eq!(members.len(), 2, "a member with no valid character is left out");
        assert!(text.contains("alice_\\\"q\\\"_example") && text.contains("main = true") && text.contains("rank = nil") && text.contains("altRank = \"Alt\""));
        assert!(!text.contains("Bad-Realm") && !text.contains("Carol"));
        let none = render_roster(None);
        assert!(lua::parse(none.as_bytes()).unwrap().is_empty() && !none.contains("Alice"));

        let dir = tempfile::tempdir().unwrap();
        let addon = dir.path().join("Emberlight");
        fs::create_dir_all(&addon).unwrap();
        fs::write(addon.join("Emberlight.toc"), "## Interface: 16001\n").unwrap();
        write_roster(dir.path(), Some(&roster)).unwrap();
        write_data_addon(dir.path(), &Archive::default()).unwrap();
        let data = dir.path().join(ADDON_DIR);
        assert!(fs::read_to_string(data.join(ROSTER_FILE)).unwrap().contains("Bob Example"), "writing the notices keeps the roster");
        assert!(fs::read_to_string(data.join(format!("{ADDON_DIR}.toc"))).unwrap().ends_with("Data.lua\nRoster.lua\nCrafting.lua\nLatest.lua\nBank.lua\nWayfarers.lua\n"));
        write_roster(dir.path(), None).unwrap();
        assert!(!fs::read_to_string(data.join(ROSTER_FILE)).unwrap().contains("Bob"));
    }

    #[test]
    fn latest_file_holds_only_a_plain_version() {
        assert_eq!(render_latest(Some("0.9.1"), 5), "EmberlightLatest = {\n\tformat = 1,\n\tchecked = 5,\n\taddon = \"0.9.1\",\n}\n");
        for bad in ["0.9", "0.9.1\"..x", "", "1..2", "a.b.c"] {
            assert!(!render_latest(Some(bad), 5).contains("addon ="), "{bad}");
        }
        let text = render_latest(Some("1.2.3"), 9);
        let parsed = lua::parse(text.as_bytes()).unwrap();
        let latest = parsed["EmberlightLatest"].as_table().unwrap();
        assert_eq!(field(latest, "addon").and_then(Value::as_bytes), Some(&b"1.2.3"[..]));
        assert_eq!(field(latest, "checked").and_then(Value::as_int), Some(9));
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
