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
    /// A Story Event (19 November 2026): an official event (category 4) the server marks as one.
    /// Only the server's download carries it; it is written to `Emberlight_Data` for the addon and
    /// never uploaded (the game's own records do not say it).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub story: bool,
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

/// The guild bank log, as an officer's addon read it when they opened the guild bank
/// (`localData.bankScans`, Emberlight/Core/GuildBank.lua, addon 0.8.14). Uploaded only for an
/// officer; the server checks the rank, the character and every line again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BankScan {
    pub character: String,
    pub scanned_at: i64,
    /// The gold the bank held, in copper, when the game said.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bank_money: Option<i64>,
    pub tabs: Vec<BankTab>,
    pub money: Vec<BankLine>,
    /// What lay in each tab and its Info text (addon 1.0.1, the newest scan only). `None` from an
    /// older addon: then the field is left out and the server keeps what it had.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contents: Option<Vec<BankContents>>,
    /// Each guild rank's bank settings, read by the guild master's addon only (addon 1.0.1).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ranks: Option<Vec<BankRank>>,
}

/// One tab as the addon saw it. `slots` is `None` when this character cannot look inside the tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BankContents {
    pub tab: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub slots: Option<Vec<BankSlot>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BankSlot {
    pub slot: i64,
    pub item_id: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    pub count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quality: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stack: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BankRank {
    pub index: i64,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gold_per_day: Option<i64>,
    pub tabs: Vec<BankRankTab>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BankRankTab {
    pub tab: i64,
    pub view: bool,
    pub deposit: bool,
    pub edit_text: bool,
    pub stacks_per_day: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BankTab {
    pub tab: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub lines: Vec<BankLine>,
}

/// One line of a log: an item line has `item_id`/`item` and `count`, a gold line `copper`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BankLine {
    #[serde(rename = "type")]
    pub kind: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub copper: Option<i64>,
    /// How long ago, in whole hours, as the game said; `rough` when it counted months or years.
    pub hours: i64,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub rough: bool,
}

const BANK_LINES: usize = 100;

/// The tables in a list field (`contents`, `slots`, `ranks`), or `None` when it is missing.
fn table_list<'a>(t: &'a Table, key: &str) -> Option<Vec<&'a Table>> {
    field(t, key).and_then(Value::as_table).map(|t| t.values().filter_map(Value::as_table).collect())
}

/// The guild bank scans in one SavedVariables file, newest first. A line or tab that is not in the
/// expected shape is left out; the server checks again.
pub fn export_bank_scans(globals: &BTreeMap<String, Value>) -> Vec<BankScan> {
    let mut out = Vec::new();
    let scans = globals
        .get("EmberlightDB")
        .and_then(Value::as_table)
        .and_then(|db| field(db, "localData"))
        .and_then(Value::as_table)
        .and_then(|l| field(l, "bankScans"))
        .and_then(Value::as_table);
    let text = |v: Option<&Value>, max: usize| {
        v.and_then(Value::as_bytes)
            .and_then(|b| std::str::from_utf8(b).ok())
            .map(str::trim)
            .filter(|t| !t.is_empty() && t.len() <= max * 4 && t.chars().count() <= max && clean(t))
            .map(str::to_owned)
    };
    let int = |v: Option<&Value>, min: i64, max: i64| v.and_then(Value::as_int).filter(|n| (min..=max).contains(n));
    let line = |t: &Table, gold: bool| -> Option<BankLine> {
        let kind = text(field(t, "type"), 20).filter(|k| k.bytes().all(|b| b.is_ascii_alphabetic()))?;
        let name = text(field(t, "name"), 60)?;
        let hours = int(field(t, "hours"), 0, 200_000)?;
        let rough = field(t, "rough").and_then(Value::as_bool) == Some(true);
        if gold {
            let copper = int(field(t, "copper"), 1, 100_000_000_000)?;
            Some(BankLine { kind, name, item_id: None, item: None, count: None, copper: Some(copper), hours, rough })
        } else {
            let count = int(field(t, "count"), 1, 100_000)?;
            let item_id = int(field(t, "itemId"), 1, 10_000_000);
            let item = text(field(t, "item"), 100);
            Some(BankLine { kind, name, item_id, item, count: Some(count), copper: None, hours, rough })
        }
    };
    for scan in scans.into_iter().flat_map(|t| t.values()).filter_map(Value::as_table) {
        let (Some(character), Some(scanned_at)) = (text(field(scan, "character"), 120), int(field(scan, "at"), 1, i64::MAX)) else { continue };
        let mut tabs = Vec::new();
        for tab in field(scan, "tabs").and_then(Value::as_table).into_iter().flat_map(|t| t.values()).filter_map(Value::as_table) {
            let Some(number) = int(field(tab, "tab"), 1, 12) else { continue };
            let lines: Vec<BankLine> = field(tab, "lines").and_then(Value::as_table).into_iter().flat_map(|t| t.values()).filter_map(Value::as_table).filter_map(|l| line(l, false)).take(BANK_LINES).collect();
            tabs.push(BankTab { tab: number, name: text(field(tab, "name"), 40), lines });
        }
        tabs.truncate(12);
        let money = field(scan, "money").and_then(Value::as_table).into_iter().flat_map(|t| t.values()).filter_map(Value::as_table).filter_map(|l| line(l, true)).take(BANK_LINES).collect();
        // The Info text keeps its line breaks; anything else that could confuse a reader is dropped.
        let info = |v: Option<&Value>| {
            v.and_then(Value::as_bytes).and_then(|b| std::str::from_utf8(b).ok()).map(|t| {
                let kept: String = t.chars().filter(|c| *c == '\n' || (!c.is_control() && *c != '|')).take(2047).collect();
                kept.trim().to_owned()
            })
        };
        let contents = table_list(scan, "contents").map(|tabs| {
            let mut out: Vec<BankContents> = tabs.into_iter().filter_map(|t| {
                let tab = int(field(t, "tab"), 1, 12)?;
                let slots = table_list(t, "slots").map(|slots| {
                    let mut kept: Vec<BankSlot> = slots.into_iter().filter_map(|s| Some(BankSlot {
                        slot: int(field(s, "slot"), 1, 98)?,
                        item_id: int(field(s, "itemId"), 1, 10_000_000)?,
                        item: text(field(s, "item"), 100),
                        count: int(field(s, "count"), 1, 100_000)?,
                        quality: int(field(s, "quality"), 0, 10),
                        stack: int(field(s, "stack"), 1, 100_000),
                    })).collect();
                    kept.sort_by_key(|s| s.slot);
                    kept.dedup_by_key(|s| s.slot);
                    kept
                });
                Some(BankContents { tab, name: text(field(t, "name"), 40), icon: int(field(t, "icon"), 0, i64::MAX / 2), text: info(field(t, "text")), slots })
            }).collect();
            out.sort_by_key(|t| t.tab);
            out.dedup_by_key(|t| t.tab);
            out
        });
        let ranks = table_list(scan, "ranks").map(|ranks| {
            ranks.into_iter().filter_map(|r| Some(BankRank {
                index: int(field(r, "index"), 0, 20)?,
                name: text(field(r, "name"), 40)?,
                gold_per_day: int(field(r, "goldPerDay"), 0, 10_000_000),
                tabs: table_list(r, "tabs").unwrap_or_default().into_iter().filter_map(|t| Some(BankRankTab {
                    tab: int(field(t, "tab"), 1, 12)?,
                    view: field(t, "view").and_then(Value::as_bool) == Some(true),
                    deposit: field(t, "deposit").and_then(Value::as_bool) == Some(true),
                    edit_text: field(t, "editText").and_then(Value::as_bool) == Some(true),
                    stacks_per_day: int(field(t, "stacksPerDay"), 0, 100_000).unwrap_or(0),
                })).take(12).collect(),
            })).take(20).collect::<Vec<_>>()
        });
        out.push(BankScan { character, scanned_at, bank_money: int(field(scan, "bankMoney"), 0, i64::MAX / 2), tabs, money, contents, ranks });
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.scanned_at));
    out
}

/// When a guildmate's character was last in game, as this member's addon read it from the guild
/// window (`localData.guildSeen.characters`, Emberlight/Core/GuildSeen.lua, addon 0.8.15): the
/// character's identity and a time to the hour. For the officers' activity overview; the server
/// matches each name to a member's verified character and keeps only later times.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameSeen {
    pub character: String,
    pub seen_at: i64,
}

/// The most characters sent in one sync (a guild far larger than this one still fits).
pub const GAME_SEEN_MAX: usize = 1500;

/// The guild window's "last online" times in one SavedVariables file. An entry that is not a plain
/// identity with a time is left out; the server checks again.
pub fn export_game_seen(globals: &BTreeMap<String, Value>) -> Vec<GameSeen> {
    let list = globals
        .get("EmberlightDB")
        .and_then(Value::as_table)
        .and_then(|db| field(db, "localData"))
        .and_then(Value::as_table)
        .and_then(|l| field(l, "guildSeen"))
        .and_then(Value::as_table)
        .and_then(|g| field(g, "characters"))
        .and_then(Value::as_table);
    let mut out = Vec::new();
    for (key, value) in list.into_iter().flat_map(|t| t.iter()) {
        let Some(character) = identity_key(key) else { continue };
        let Some(seen_at) = value.as_int().filter(|n| *n > 0) else { continue };
        out.push(GameSeen { character, seen_at });
    }
    out
}

fn identity_key(key: &Key) -> Option<String> {
    let Key::Str(bytes) = key else { return None };
    let t = std::str::from_utf8(bytes).ok()?;
    let ok = !t.is_empty() && t.len() <= 120 && t.contains('-') && clean(t) && !t.chars().any(char::is_whitespace);
    ok.then(|| t.to_owned())
}

/// The professions this account's characters have, as the addon recorded them under
/// `localData.professions` (Emberlight/Core/Professions.lua, addon 0.8.13): levels from the skill
/// list, recipes from the profession windows. Uploaded for the member's own verified characters
/// only; the server checks every name and number again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfessionScan {
    pub character: String,
    /// When the addon last saw something change for this character.
    pub scanned_at: i64,
    /// False when a collapsed header hid part of the skill list: nothing is dropped then.
    pub complete: bool,
    pub skills: Vec<Skill>,
    pub recipes: Vec<SkillRecipes>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Skill {
    pub skill: String,
    pub rank: i64,
    pub max: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkillRecipes {
    pub skill: String,
    pub list: Vec<Recipe>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recipe {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spell_id: Option<i64>,
    /// The materials the profession window listed (addon 0.8.13 and later); empty when unknown.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reagents: Vec<Reagent>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reagent {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item_id: Option<i64>,
    pub count: i64,
}

/// The professions the website lists (server/src/professions.ts).
pub const SKILLS: [&str; 12] = ["Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism", "Leatherworking", "Mining", "Skinning", "Tailoring", "Cooking", "First Aid", "Fishing"];
const MAX_RECIPES: usize = 600;
const MAX_REAGENTS: usize = 8;

/// Every character's recorded professions in one SavedVariables file.
pub fn export_professions(globals: &BTreeMap<String, Value>) -> Vec<ProfessionScan> {
    read_professions(globals, "professions", false)
}

/// Professions guildmates' addons shared in game (`localData.relayedProfessions`, addon 0.8.13),
/// for members without the Companion. A recipe may have no name yet (only its item or spell
/// number): the server takes the name another member's game gave it.
pub fn export_relayed_professions(globals: &BTreeMap<String, Value>) -> Vec<ProfessionScan> {
    read_professions(globals, "relayedProfessions", true)
}

fn read_professions(globals: &BTreeMap<String, Value>, key: &str, relayed: bool) -> Vec<ProfessionScan> {
    let mut out = Vec::new();
    let all = globals
        .get("EmberlightDB")
        .and_then(Value::as_table)
        .and_then(|db| field(db, "localData"))
        .and_then(Value::as_table)
        .and_then(|l| field(l, key))
        .and_then(Value::as_table);
    let text = |v: Option<&Value>| v.and_then(Value::as_bytes).and_then(|b| std::str::from_utf8(b).ok()).map(str::to_owned);
    let id = |v: Option<&Value>| v.and_then(Value::as_int).filter(|n| (1..10_000_000).contains(n));
    for (key, entry) in all.into_iter().flatten() {
        let (Key::Str(character), Some(entry)) = (key, entry.as_table()) else { continue };
        let Ok(character) = std::str::from_utf8(character) else { continue };
        let Some(scanned_at) = field(entry, "at").and_then(Value::as_int).filter(|t| *t > 0) else { continue };
        if !valid_owner(character) {
            continue;
        }
        let mut scan = ProfessionScan { character: character.to_owned(), scanned_at, complete: field(entry, "complete").and_then(Value::as_bool) != Some(false), skills: Vec::new(), recipes: Vec::new() };
        let skills = field(entry, "skills").and_then(Value::as_table);
        let recipes = field(entry, "recipes").and_then(Value::as_table);
        for skill in SKILLS {
            let Some(s) = skills.and_then(|t| field(t, skill)).and_then(Value::as_table) else { continue };
            let (Some(rank), Some(max)) = (field(s, "rank").and_then(Value::as_int), field(s, "max").and_then(Value::as_int)) else { continue };
            if !(0..=1000).contains(&rank) || !(1..=1000).contains(&max) || rank > max {
                continue;
            }
            scan.skills.push(Skill { skill: skill.to_owned(), rank, max });
            let mut list: Vec<Recipe> = recipes
                .and_then(|t| field(t, skill))
                .and_then(Value::as_table)
                .into_iter()
                .flat_map(|t| t.values())
                .filter_map(Value::as_table)
                .filter_map(|r| {
                    let ok = |name: &str| !name.is_empty() && name.len() <= 100 && !name.contains('|') && clean(name);
                    let (item_id, spell_id) = (id(field(r, "item")), id(field(r, "spell")));
                    let name = match text(field(r, "name")).map(|n| n.trim().to_owned()) {
                        Some(name) if ok(&name) => name,
                        // A shared recipe the receiving game had not named yet.
                        None if relayed && (item_id.is_some() || spell_id.is_some()) => String::new(),
                        _ => return None,
                    };
                    // Every material or none: a half list would mislead, and one bad entry makes
                    // the server refuse the whole report.
                    let reagents: Option<Vec<Reagent>> = field(r, "reagents")
                        .and_then(Value::as_table)
                        .map(|t| t.values().filter_map(Value::as_table).map(|g| {
                            let name = text(field(g, "name"))?.trim().to_owned();
                            let count = field(g, "count").and_then(Value::as_int).filter(|c| (1..=100).contains(c))?;
                            ok(&name).then(|| Reagent { name, item_id: id(field(g, "item")), count })
                        }).collect::<Option<Vec<_>>>().unwrap_or_default())
                        .filter(|list| list.len() <= MAX_REAGENTS);
                    Some(Recipe { name, item_id, spell_id, reagents: if relayed { Vec::new() } else { reagents.unwrap_or_default() } })
                })
                .collect();
            list.sort_by(|a, b| (&a.name, a.item_id, a.spell_id).cmp(&(&b.name, b.item_id, b.spell_id)));
            list.truncate(MAX_RECIPES);
            if !list.is_empty() {
                scan.recipes.push(SkillRecipes { skill: skill.to_owned(), list });
            }
        }
        out.push(scan);
    }
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
        story: false,
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

/// The name part of an identity, with its "-": `alice_example-`.
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
        let linked = ["alice_example-classicbetapve2".to_string()];
        assert!(owns(&linked, "alice_example-classicbetapve"));
        assert!(owns(&linked, "alice_example-classicbetapve2"));
        assert!(!owns(&linked, "bob_example-classicbetapve2"));
        assert!(!owns(&linked, "alice"));
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
            story: false,
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
    fn shared_professions_may_lack_names_but_not_numbers() {
        let src = br#"EmberlightDB = { localData = { relayedProfessions = {
            ["bob_example-testrealm"] = { at = 1800000000, complete = true, received = 1800000005,
                skills = { Tailoring = { rank = 60, max = 75 } },
                recipes = { Tailoring = { ["i:2569"] = { item = 2569 }, ["i:4343"] = { item = 4343, name = "Brown Linen Pants" }, ["n:x"] = { } } } },
        } } }"#;
        let globals = crate::lua::parse(src).unwrap();
        assert!(export_professions(&globals).is_empty());
        let scans = export_relayed_professions(&globals);
        assert_eq!(scans.len(), 1);
        assert_eq!(scans[0].recipes[0].list, vec![
            Recipe { name: "".into(), item_id: Some(2569), spell_id: None, reagents: vec![] },
            Recipe { name: "Brown Linen Pants".into(), item_id: Some(4343), spell_id: None, reagents: vec![] },
        ]);
    }

    #[test]
    fn guild_window_last_online_times_are_read_and_sent_in_the_server_shape() {
        let src = br#"EmberlightDB = { schemaVersion = 3, localData = { guildSeen = { at = 1800003600, characters = {
            ["alice_example-testrealm"] = 1800000000,
            ["no realm"] = 1800000000,
            ["bad|name-testrealm"] = 1800000000,
            ["bob_example-testrealm"] = "soon",
            [1] = 1800000000,
        } } } }"#;
        let seen = export_game_seen(&crate::lua::parse(src).unwrap());
        assert_eq!(seen, vec![GameSeen { character: "alice_example-testrealm".into(), seen_at: 1800000000 }]);
        assert_eq!(serde_json::to_value(&seen[0]).unwrap(), serde_json::json!({ "character": "alice_example-testrealm", "seenAt": 1800000000 }));
        assert!(export_game_seen(&crate::lua::parse(b"EmberlightDB = { localData = {} }").unwrap()).is_empty());
    }

    #[test]
    fn guild_bank_scans_are_read_and_sent_in_the_server_shape() {
        let src = br#"EmberlightDB = { schemaVersion = 3, localData = { bankScans = {
            { at = 1800000600, character = "Keeper Example-TestRealm", bankMoney = 1234567,
              tabs = { { tab = 1, name = "Cloth", lines = { { type = "deposit", name = "Alice Example", itemId = 2589, item = "Linen Cloth", count = 20, hours = 3 },
                                                             { type = "withdraw", name = "Bad|Name", itemId = 1, count = 1, hours = 1 } } } },
              money = { { type = "deposit", name = "Alice Example", copper = 50000, hours = 1 }, { type = "repair", name = "Bob Example", copper = 1234, hours = 1460, rough = true }, { type = "deposit", name = "Zero", copper = 0, hours = 1 } } },
            { at = 1800000000, character = "Keeper Example-TestRealm", tabs = {}, money = {} },
            { character = "No Time-TestRealm" },
        } } }"#;
        let scans = export_bank_scans(&crate::lua::parse(src).unwrap());
        assert_eq!(scans.len(), 2);
        assert_eq!(scans[0].scanned_at, 1800000600);
        assert_eq!(scans[0].bank_money, Some(1234567));
        assert_eq!(scans[0].tabs[0].lines.len(), 1, "a name with markup is left out");
        assert_eq!(scans[0].money.len(), 2, "a line without gold is left out");
        assert_eq!(scans[1].bank_money, None);
        let json = serde_json::to_value(&scans[0]).unwrap();
        assert_eq!(json["scannedAt"], 1800000600);
        assert_eq!(json["bankMoney"], 1234567);
        assert_eq!(json["tabs"][0]["lines"][0], serde_json::json!({ "type": "deposit", "name": "Alice Example", "itemId": 2589, "item": "Linen Cloth", "count": 20, "hours": 3 }));
        assert_eq!(json["money"][1], serde_json::json!({ "type": "repair", "name": "Bob Example", "copper": 1234, "hours": 1460, "rough": true }));
    }

    #[test]
    fn guild_bank_contents_and_ranks_are_sent_when_the_addon_read_them() {
        let src = br#"EmberlightDB = { schemaVersion = 3, localData = { bankScans = {
            { at = 1800000600, character = "Keeper Example-TestRealm", tabs = {}, money = {},
              contents = { { tab = 1, name = "Cloth", icon = 133784, text = "Cloth here.\nThank you!",
                             slots = { { slot = 2, itemId = 2589, item = "Linen Cloth", count = 20, quality = 1, stack = 20 }, { slot = 99, itemId = 1, count = 1 }, { slot = 3, itemId = 2592, count = 0 } } },
                           { tab = 2, name = "Officers" } },
              ranks = { { index = 1, name = "Flame Keeper", goldPerDay = 50, tabs = { { tab = 1, view = true, deposit = true, editText = false, stacksPerDay = 5 } } } } },
            { at = 1800000000, character = "Keeper Example-TestRealm", tabs = {}, money = {} },
        } } }"#;
        let scans = export_bank_scans(&crate::lua::parse(src).unwrap());
        let contents = scans[0].contents.as_ref().unwrap();
        assert_eq!(contents[0].slots.as_ref().unwrap().len(), 1, "a slot out of range or with no items is left out");
        assert_eq!(contents[1].slots, None, "a tab this character cannot look inside has no slots");
        assert_eq!(scans[1].contents, None);
        let json = serde_json::to_value(&scans[0]).unwrap();
        assert_eq!(json["contents"][0], serde_json::json!({ "tab": 1, "name": "Cloth", "icon": 133784, "text": "Cloth here.\nThank you!", "slots": [{ "slot": 2, "itemId": 2589, "item": "Linen Cloth", "count": 20, "quality": 1, "stack": 20 }] }));
        assert_eq!(json["ranks"][0], serde_json::json!({ "index": 1, "name": "Flame Keeper", "goldPerDay": 50, "tabs": [{ "tab": 1, "view": true, "deposit": true, "editText": false, "stacksPerDay": 5 }] }));
        assert!(serde_json::to_value(&scans[1]).unwrap().get("contents").is_none(), "an older scan sends no contents field");
    }

    #[test]
    fn professions_are_read_from_local_data() {
        let src = br#"EmberlightDB = { schemaVersion = 3, localData = { professions = {
            ["nora_everwood-testrealm"] = { at = 1800000000, complete = true,
                skills = { Mining = { rank = 64, max = 125 }, Blacksmithing = { rank = 80, max = 150 }, Swords = { rank = 1, max = 300 }, Tailoring = { rank = 99, max = 75 } },
                recipes = { Blacksmithing = { ["i:2661"] = { name = "Copper Chain Belt", item = 2661, reagents = { { name = "Copper Bar", item = 2840, count = 6 } } }, ["i:2852"] = { name = "Rough Copper Vest", item = 2852, reagents = { { name = "Copper Bar", count = 0 } } }, ["n:x"] = { name = "Bad|Hlink" } } } },
            ["hidden_one-testrealm"] = { at = 1800000001, complete = true, hidden = true, skills = {}, recipes = {} },
            ["Not Valid"] = { at = 1, skills = {} },
        } } }"#;
        let scans = export_professions(&crate::lua::parse(src).unwrap());
        assert_eq!(scans.len(), 2);
        let hidden = scans.iter().find(|s| s.character == "hidden_one-testrealm").unwrap();
        assert!(hidden.complete && hidden.skills.is_empty());
        let nora = scans.iter().find(|s| s.character == "nora_everwood-testrealm").unwrap();
        assert_eq!(nora.skills, vec![Skill { skill: "Blacksmithing".into(), rank: 80, max: 150 }, Skill { skill: "Mining".into(), rank: 64, max: 125 }]);
        assert_eq!(nora.recipes, vec![SkillRecipes { skill: "Blacksmithing".into(), list: vec![
            Recipe { name: "Copper Chain Belt".into(), item_id: Some(2661), spell_id: None, reagents: vec![Reagent { name: "Copper Bar".into(), item_id: Some(2840), count: 6 }] },
            Recipe { name: "Rough Copper Vest".into(), item_id: Some(2852), spell_id: None, reagents: vec![] },
        ] }]);
        let json = serde_json::to_value(&nora.recipes[0].list[0]).unwrap();
        assert_eq!(json["reagents"][0], serde_json::json!({ "name": "Copper Bar", "itemId": 2840, "count": 6 }));
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
