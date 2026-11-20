//! Platform-independent logic of the Renatus admin app (officers and editor):
//! reading the addon's journal (SavedVariables) and combat logs, the rival guild
//! from the armory, the AI gazette, and writing Renatus_Admin/Press.lua. The
//! Tauri shell (src-tauri, Windows only) and the `renatus-admin` command line
//! both drive `ops`.

pub mod addon;
pub mod armory;
pub mod articles;
pub mod chronicle;
pub mod combatlog;
pub mod config;
pub mod gazette;
pub mod llm;
pub mod lua;
pub mod ops;
pub mod paths;
pub mod press;
