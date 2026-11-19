//! Locating the World of Warcraft Forever client folder (`_forever_`).

use std::path::{Path, PathBuf};

pub const FLAVOR: &str = "_forever_";

/// Folders under which Battle.net usually installs the game, per drive.
const USUAL_ROOTS: &[&str] = &[
    r"World of Warcraft",
    r"Program Files (x86)\World of Warcraft",
    r"Program Files\World of Warcraft",
    r"Games\World of Warcraft",
    r"Jeux\World of Warcraft",
    r"MyGames\World of Warcraft",
    r"Battle.net\World of Warcraft",
    r"Blizzard\World of Warcraft",
];

/// Turns any folder the player could point at (the game folder, `_forever_`,
/// `_forever_\Interface`, `_forever_\Interface\AddOns`, or another flavor
/// such as `_retail_` from the registry) into the `_forever_` folder.
pub fn resolve_flavor_dir(path: &Path) -> Option<PathBuf> {
    for dir in path.ancestors().take(4) {
        if dir.file_name().is_some_and(|n| n == FLAVOR) && dir.is_dir() {
            return Some(dir.to_path_buf());
        }
        let child = dir.join(FLAVOR);
        if child.is_dir() {
            return Some(child);
        }
    }
    None
}

pub fn addons_dir(flavor_dir: &Path) -> PathBuf {
    flavor_dir.join("Interface").join("AddOns")
}

/// Places to try, in order: paths read from the registry, then the usual
/// install folders on each drive.
pub fn candidates(registry: &[PathBuf], drives: &[char]) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = registry.to_vec();
    for drive in drives {
        for root in USUAL_ROOTS {
            out.push(PathBuf::from(format!(r"{drive}:\{root}")));
        }
    }
    out
}

/// First candidate that leads to a `_forever_` folder.
pub fn detect(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find_map(|c| resolve_flavor_dir(c))
}
