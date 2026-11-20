//! Calling the AI through an external command (default: Claude Code, non-interactive).
//!
//! The prompt is written to the command's standard input; the answer is read from
//! its output. Examples:
//!   - Claude Code on this PC:
//!     `["claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence"]`
//!   - Claude Code on another machine (Raspberry Pi) over SSH (passwordless key):
//!     `["ssh", "pi5", "cd /tmp && ~/.local/bin/claude -p --output-format json --tools '' --no-session-persistence"]`
//!     (over SSH the remote command is a single string: the empty argument is written '' in it.)
//!
//! The AI gets no tools (`--tools ""`): it only reads the prompt and answers.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

pub fn default_command() -> Vec<String> {
    [
        "claude",
        "-p",
        "--output-format",
        "json",
        "--tools",
        "",
        "--no-session-persistence",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

pub fn run(prompt: &str, command: &[String], timeout: Duration) -> Result<String, String> {
    let (program, args) = command.split_first().ok_or("commande de l'IA vide")?;
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("commande introuvable : {program} ({e})"))?;

    let mut stdin = child.stdin.take().ok_or("entrée standard indisponible")?;
    let input = prompt.as_bytes().to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let mut stdout = child.stdout.take().ok_or("sortie standard indisponible")?;
    let mut stderr = child.stderr.take().ok_or("sortie d'erreur indisponible")?;
    let out_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stdout.read_to_end(&mut buf);
        buf
    });
    let err_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = stderr.read_to_end(&mut buf);
        buf
    });

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("pas de réponse après {} s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(200));
    };
    let _ = writer.join();
    let out = String::from_utf8_lossy(&out_reader.join().unwrap_or_default()).into_owned();
    let err = String::from_utf8_lossy(&err_reader.join().unwrap_or_default())
        .trim()
        .to_string();
    if !status.success() {
        let detail = if err.is_empty() { &out } else { &err };
        let tail: String = detail
            .chars()
            .rev()
            .take(500)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        return Err(format!(
            "la commande a échoué (code {}) : {tail}",
            status.code().map_or("?".into(), |c| c.to_string())
        ));
    }
    unwrap(&out)
}

/// Claude Code `--output-format json` output -> answer text; otherwise the raw text.
pub fn unwrap(out: &str) -> Result<String, String> {
    let text = out.trim();
    let Ok(data) = serde_json::from_str::<Value>(text) else {
        return Ok(text.to_string());
    };
    if data.get("type").and_then(Value::as_str) == Some("result") {
        if let Some(result) = data.get("result") {
            let result = result
                .as_str()
                .map_or_else(|| result.to_string(), str::to_string);
            if data.get("is_error").and_then(Value::as_bool) == Some(true) {
                let short: String = result.chars().take(500).collect();
                return Err(format!("erreur de l'IA : {short}"));
            }
            return Ok(result);
        }
    }
    // the command returned the articles JSON directly
    Ok(text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwraps_claude_code_json() {
        assert_eq!(
            unwrap(r#"{"type":"result","result":"{\"articles\":[]}"}"#).unwrap(),
            r#"{"articles":[]}"#
        );
        assert!(
            unwrap(r#"{"type":"result","is_error":true,"result":"quota"}"#)
                .unwrap_err()
                .contains("quota")
        );
        assert_eq!(unwrap(" plain ").unwrap(), "plain");
        assert_eq!(unwrap(r#"{"articles":[]}"#).unwrap(), r#"{"articles":[]}"#);
    }

    #[cfg(unix)]
    #[test]
    fn runs_a_command_with_stdin_and_timeout() {
        let cat = vec!["cat".to_string()];
        assert_eq!(
            run("bonjour", &cat, Duration::from_secs(5)).unwrap(),
            "bonjour"
        );
        let slow = vec!["sleep".to_string(), "5".to_string()];
        assert!(run("", &slow, Duration::from_millis(300))
            .unwrap_err()
            .contains("pas de réponse"));
        let missing = vec!["renatus-no-such-program".to_string()];
        assert!(run("", &missing, Duration::from_secs(1))
            .unwrap_err()
            .contains("introuvable"));
    }
}
