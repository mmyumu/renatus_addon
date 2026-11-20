//! Game files the admin app reads (and the one it writes, Renatus_Admin/Press.lua).

use std::fs;
use std::path::{Path, PathBuf};

pub const SV_NAME: &str = "Renatus.lua";
pub const ADMIN_ADDON: &str = "Renatus_Admin";

#[derive(Debug, Clone)]
pub struct WowPaths {
    /// The `_forever_` folder.
    pub root: PathBuf,
    /// Account folder under WTF/Account (None: the only one holding Renatus data).
    pub account: Option<String>,
}

impl WowPaths {
    pub fn new(root: impl Into<PathBuf>, account: Option<String>) -> Self {
        Self {
            root: root.into(),
            account: account.filter(|a| !a.trim().is_empty()),
        }
    }

    pub fn addons(&self) -> PathBuf {
        self.root.join("Interface").join("AddOns")
    }

    pub fn admin_addon(&self) -> PathBuf {
        self.addons().join(ADMIN_ADDON)
    }

    pub fn press(&self) -> PathBuf {
        self.admin_addon().join("Press.lua")
    }

    pub fn logs(&self) -> PathBuf {
        self.root.join("Logs")
    }

    pub fn accounts_with_data(&self) -> Vec<String> {
        let base = self.root.join("WTF").join("Account");
        let Ok(entries) = fs::read_dir(&base) else {
            return Vec::new();
        };
        let mut out: Vec<String> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.path().join("SavedVariables").join(SV_NAME).is_file())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        out.sort();
        out
    }

    pub fn saved_variables(&self) -> Result<PathBuf, String> {
        let account = match &self.account {
            Some(a) => a.clone(),
            None => {
                let found = self.accounts_with_data();
                match found.len() {
                    1 => found[0].clone(),
                    0 => {
                        return Err(format!(
                        "Aucun {SV_NAME} sous {} : lance le jeu avec l'addon puis fais /reload.",
                        self.root.join("WTF").join("Account").display()
                    ))
                    }
                    _ => {
                        return Err(format!(
                            "Plusieurs comptes trouvés ({}) : choisis le compte.",
                            found.join(", ")
                        ))
                    }
                }
            }
        };
        Ok(self
            .root
            .join("WTF")
            .join("Account")
            .join(account)
            .join("SavedVariables")
            .join(SV_NAME))
    }

    /// Combat logs, oldest first.
    pub fn combat_logs(&self) -> Vec<PathBuf> {
        let Ok(entries) = fs::read_dir(self.logs()) else {
            return Vec::new();
        };
        let mut logs: Vec<(std::time::SystemTime, PathBuf)> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("WoWCombatLog") && n.ends_with(".txt"))
            })
            .filter_map(|p| Some((fs::metadata(&p).ok()?.modified().ok()?, p)))
            .collect();
        logs.sort();
        logs.into_iter().map(|(_, p)| p).collect()
    }
}

/// A Windows path ("C:/...") seen from WSL or Linux becomes /mnt/c/...; anything else is kept.
pub fn local_path(root: &str) -> PathBuf {
    let b = root.as_bytes();
    if !cfg!(windows)
        && b.len() > 2
        && b[0].is_ascii_alphabetic()
        && b[1] == b':'
        && matches!(b[2], b'/' | b'\\')
    {
        let drive = (b[0] as char).to_ascii_lowercase();
        let mnt = Path::new("/mnt").join(drive.to_string());
        if mnt.is_dir() {
            return mnt.join(root[3..].replace('\\', "/"));
        }
    }
    PathBuf::from(root)
}
