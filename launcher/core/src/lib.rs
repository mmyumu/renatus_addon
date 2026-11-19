//! Platform-independent logic of the Renatus launcher: finding the game,
//! choosing the release to install, installing it, and the saved settings.
//! The Tauri shell (src-tauri, Windows only) wires these to the UI, the
//! network and the system tray.

pub mod addon;
pub mod config;
pub mod release;
pub mod wow;

#[cfg(test)]
mod tests;
