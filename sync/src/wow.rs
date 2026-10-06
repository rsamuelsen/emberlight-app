//! Detect a running game client. The sync tool never writes into a WoW folder while one runs.

use std::path::Path;
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, RefreshKind, System, UpdateKind};

const CLIENT_NAMES: &[&str] = &[
    "wow.exe",
    "wowt.exe",
    "wowb.exe",
    "wowclassic.exe",
    "wowclassict.exe",
    "wowclassicb.exe",
    "world of warcraft",
    "world of warcraft classic",
];

/// Programs that live in the game folder but are not the game: Battle.net and the client's own
/// helpers, which can stay behind for a while after the game has closed.
const NOT_THE_GAME: &[&str] = &["battle.net", "voiceproxy", "blizzarderror", "blizzardbrowser"];

/// Whether a process (lower-case name, path of its program) is a game client: a known client name,
/// or any other program inside `root`, so a client with a new name still counts.
fn is_client(name: &str, exe: Option<&Path>, root: Option<&Path>) -> bool {
    CLIENT_NAMES.contains(&name)
        || (root.is_some_and(|r| exe.is_some_and(|exe| exe.starts_with(r))) && !NOT_THE_GAME.iter().any(|n| name.contains(n)))
}

/// A process list that can be read again and again, for watching the game start and close.
pub struct Clients(System);

impl Default for Clients {
    fn default() -> Self {
        Self::new()
    }
}

impl Clients {
    pub fn new() -> Self {
        Self(System::new_with_specifics(RefreshKind::nothing()))
    }

    /// Names of running processes that are game clients, read fresh on every call.
    pub fn running(&mut self, root: Option<&Path>) -> Vec<String> {
        self.0.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_exe(UpdateKind::OnlyIfNotSet));
        let mut out: Vec<String> = self
            .0
            .processes()
            .values()
            .filter_map(|p| {
                let name = p.name().to_string_lossy().to_lowercase();
                is_client(&name, p.exe(), root).then_some(name)
            })
            .collect();
        out.sort();
        out.dedup();
        out
    }
}

/// Names of running processes that are known game clients or live inside `root`.
/// Battle.net and the client's helper programs are not counted.
pub fn running_clients(root: Option<&Path>) -> Vec<String> {
    Clients::new().running(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn tells_the_game_from_its_helpers() {
        let root = PathBuf::from("games").join("World of Warcraft");
        let inside = |file: &str| root.join("_retail_").join(file);
        let check = |name: &str, exe: &Path| is_client(name, Some(exe), Some(&root));
        assert!(check("wow.exe", &inside("Wow.exe")));
        assert!(check("wowforever.exe", &inside("WowForever.exe")));
        assert!(is_client("wow.exe", None, None));
        assert!(!check("wowvoiceproxy.exe", &inside("WowVoiceProxy.exe")));
        assert!(!check("blizzarderror.exe", &inside("BlizzardError.exe")));
        assert!(!check("battle.net.exe", &inside("Battle.net.exe")));
        assert!(!check("notepad.exe", &PathBuf::from("windows").join("notepad.exe")));
    }
}
