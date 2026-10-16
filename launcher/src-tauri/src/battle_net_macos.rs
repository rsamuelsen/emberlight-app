//! Launch Services name lookup alone can miss an installed Battle.net bundle.
//! Try conventional bundle paths first, then let Launch Services find custom installs.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

fn candidates(home: Option<&Path>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for applications in
        std::iter::once(PathBuf::from("/Applications")).chain(home.map(|h| h.join("Applications")))
    {
        paths.push(applications.join("Battle.net.app"));
        paths.push(applications.join("Battle.net/Battle.net.app"));
    }
    paths
}

#[cfg(target_os = "macos")]
pub fn launch(argument: &str) -> Result<(), String> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    launch_with(
        home.as_deref(),
        argument,
        |p| p.is_dir(),
        |args| {
            let output = std::process::Command::new("/usr/bin/open")
                .args(args)
                .output()
                .map_err(|e| format!("Could not run /usr/bin/open: {e}"))?;
            open_result(
                output.status.success(),
                &output.status.to_string(),
                &output.stderr,
            )
        },
    )
}

fn open_result(success: bool, status: &str, stderr: &[u8]) -> Result<(), String> {
    if success {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(stderr);
    // Keep diagnostics useful without flooding the launcher's inline error area.
    let detail: String = detail.trim().chars().take(500).collect();
    Err(if detail.is_empty() {
        status.to_owned()
    } else {
        format!("{status}: {detail}")
    })
}

fn launch_with(
    home: Option<&Path>,
    argument: &str,
    mut is_dir: impl FnMut(&Path) -> bool,
    mut open: impl FnMut(&[OsString]) -> Result<(), String>,
) -> Result<(), String> {
    // Command does not invoke a shell. Quotes used by Windows raw_arg must not be sent
    // literally to Battle.net on macOS; --exec=launch WoW is ONE argument, spaces intact.
    let argument = OsString::from(argument.replace('"', ""));
    let mut failures = Vec::new();
    for app in candidates(home).into_iter().filter(|p| is_dir(p)) {
        let args = [
            OsString::from("-a"),
            app.as_os_str().to_owned(),
            OsString::from("--args"),
            argument.clone(),
        ];
        match open(&args) {
            Ok(()) => return Ok(()),
            Err(e) => failures.push(format!("{}: {e}", app.display())),
        }
    }
    // Registered bundles can live on another disk or outside Applications. Do not
    // scan disks or assume the WoW install directory contains the Battle.net client.
    let args = [
        OsString::from("-a"),
        OsString::from("Battle.net"),
        OsString::from("--args"),
        argument,
    ];
    match open(&args) {
        Ok(()) => Ok(()),
        Err(e) => {
            failures.push(format!("Battle.net app lookup: {e}"));
            Err(format!(
                "Could not open Battle.net. Check that Battle.net is installed and opens from Finder, then retry. If it is in a custom location, open it once from Finder so macOS can register it. You can also start the game directly from Battle.net. Details: {}",
                failures.join("; ")
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supports_system_and_user_applications_with_and_without_vendor_folder() {
        assert_eq!(
            candidates(Some(Path::new("/Users/player"))),
            vec![
                PathBuf::from("/Applications/Battle.net.app"),
                PathBuf::from("/Applications/Battle.net/Battle.net.app"),
                PathBuf::from("/Users/player/Applications/Battle.net.app"),
                PathBuf::from("/Users/player/Applications/Battle.net/Battle.net.app"),
            ]
        );
        assert_eq!(candidates(None).len(), 2);
    }

    #[test]
    fn each_supported_bundle_can_launch_without_registered_name_lookup() {
        for app in candidates(Some(Path::new("/Users/A Player"))) {
            let mut calls = Vec::new();
            let result = launch_with(
                Some(Path::new("/Users/A Player")),
                "--game=wow_classic_beta",
                |p| p == app,
                |args| {
                    calls.push(args.to_vec());
                    Ok(())
                },
            );
            assert!(result.is_ok());
            assert_eq!(
                calls,
                vec![vec![
                    OsString::from("-a"),
                    app.into_os_string(),
                    OsString::from("--args"),
                    OsString::from("--game=wow_classic_beta"),
                ]]
            );
        }
    }

    #[test]
    fn retail_exec_is_one_unquoted_argument() {
        launch_with(
            None,
            "--exec=\"launch WoW\"",
            |_| true,
            |args| {
                assert_eq!(args.len(), 4);
                assert_eq!(args[3], "--exec=launch WoW");
                Ok(())
            },
        )
        .unwrap();
    }

    #[test]
    fn missing_bundles_fall_back_to_registered_custom_location() {
        let mut calls = 0;
        launch_with(
            None,
            "--game=wow_classic_beta",
            |_| false,
            |args| {
                calls += 1;
                assert_eq!(args[1], "Battle.net");
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(calls, 1);
    }

    #[test]
    fn broken_bundle_does_not_prevent_trying_another_install() {
        let mut calls = 0;
        launch_with(
            None,
            "--game=wow_classic_beta",
            |_| true,
            |_| {
                calls += 1;
                if calls == 1 {
                    Err("invalid bundle".into())
                } else {
                    Ok(())
                }
            },
        )
        .unwrap();
        assert_eq!(calls, 2);
    }

    #[test]
    fn failed_explicit_bundles_still_allow_registered_lookup() {
        let mut calls = 0;
        launch_with(
            None,
            "--game=wow_classic_beta",
            |_| true,
            |args| {
                calls += 1;
                if args[1] == "Battle.net" {
                    Ok(())
                } else {
                    Err("unusable bundle".into())
                }
            },
        )
        .unwrap();
        assert_eq!(calls, 3);
    }

    #[test]
    fn final_error_preserves_diagnostics_and_recovery_instructions() {
        let error = launch_with(
            None,
            "--game=wow_classic_beta",
            |_| true,
            |_| Err("Launch Services denied request".into()),
        )
        .unwrap_err();
        assert!(error.contains("/Applications/Battle.net.app"));
        assert!(error.contains("Battle.net app lookup"));
        assert!(error.contains("Launch Services denied request"));
        assert!(error.contains("Finder"));
        assert!(!error.contains("was not found"));
        let error = launch_with(
            None,
            "--game=wow_classic_beta",
            |_| false,
            |_| Err("Could not run /usr/bin/open: permission denied".into()),
        )
        .unwrap_err();
        assert!(error.contains("permission denied"));
    }

    #[test]
    fn open_status_retains_stderr_or_exit_status_and_accepts_success() {
        assert!(open_result(true, "exit status: 0", b"warning").is_ok());
        assert_eq!(
            open_result(false, "exit status: 1", b"  app not registered\n").unwrap_err(),
            "exit status: 1: app not registered"
        );
        assert_eq!(
            open_result(false, "exit status: 2", b"").unwrap_err(),
            "exit status: 2"
        );
    }
}
