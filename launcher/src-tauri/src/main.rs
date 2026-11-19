#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#[cfg(windows)]
mod desktop;

fn main() {
    #[cfg(windows)]
    desktop::run();
    #[cfg(not(windows))]
    eprintln!("Le launcher Renatus est une application Windows.");
}
