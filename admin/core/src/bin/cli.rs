//! `renatus-admin`: the admin app's command line (replaces `python -m companion`).
//! Handy from WSL or Linux; the Windows window does the same things.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use renatus_admin_core::chronicle::{num_of, str_of};
use renatus_admin_core::config::Config;
use renatus_admin_core::paths::{local_path, WowPaths};
use renatus_admin_core::{addon, gazette, ops};

const HELP: &str = "Renatus admin : renatus-admin [options] <commande>

Commandes :
  status            ce que l'app voit (journal de l'addon, journaux de combat, presse en attente)
  facts [jours]     faits partagés de la période, avec leurs identifiants (défaut : 7 jours)
  deaths [fichier]  causes de mort et affrontements PvP des journaux de combat -> Press.lua
  articles [dossier] articles .md écrits à la main -> Press.lua
  gazette [--show]  gazette IA de la semaine -> Press.lua (--show : affiche la demande, n'appelle rien)
  rival [guilde]    guilde rivale depuis l'armurerie (nom ou lien) -> Press.lua
  run               deaths + articles (+ rival une fois par jour, + gazette si autoGazette)
  install-admin     installe ou met à jour l'addon Renatus_Admin depuis GitHub
  config [clé valeur]  affiche ou change un réglage (wowPath, account, rival, articlesDir,
                    llmCommand (JSON), llmTimeoutSecs, autoGazette, testChannel)

Options : --wow <dossier _forever_>  --account <compte>  --config <fichier>  --dry-run

Rien n'est publié tout seul : en jeu, /reload puis Gazette > Rédaction (addon Renatus_Admin).";

struct Args {
    wow: Option<String>,
    account: Option<String>,
    config: PathBuf,
    dry_run: bool,
    show: bool,
    rest: Vec<String>,
}

fn default_config() -> PathBuf {
    if let Ok(p) = std::env::var("RENATUS_ADMIN_CONFIG") {
        return PathBuf::from(p);
    }
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("renatus-admin").join("config.json")
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args {
        wow: None,
        account: None,
        config: default_config(),
        dry_run: false,
        show: false,
        rest: Vec::new(),
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--wow" => args.wow = Some(it.next().ok_or("--wow sans dossier")?),
            "--account" => args.account = Some(it.next().ok_or("--account sans nom")?),
            "--config" => args.config = PathBuf::from(it.next().ok_or("--config sans fichier")?),
            "--dry-run" => args.dry_run = true,
            "--show" => args.show = true,
            "-h" | "--help" => return Err(HELP.into()),
            _ => args.rest.push(a),
        }
    }
    Ok(args)
}

fn paths(args: &Args, cfg: &Config) -> Result<WowPaths, String> {
    let root = args
        .wow
        .as_deref()
        .map(local_path)
        .or_else(|| cfg.wow_path.as_ref().map(|p| local_path(&p.to_string_lossy())))
        .ok_or("Indique le dossier du jeu : --wow \"C:/…/World of Warcraft/_forever_\" (ou renatus-admin config wowPath …).")?;
    Ok(WowPaths::new(
        root,
        args.account.clone().or_else(|| cfg.account.clone()),
    ))
}

fn print_notes(notes: &[String]) {
    for n in notes {
        println!("{n}");
    }
}

fn publish(
    paths: &WowPaths,
    ch: &renatus_admin_core::chronicle::Chronicle,
    p: ops::Proposal,
    dry_run: bool,
) -> Result<(), String> {
    print_notes(&p.notes);
    if dry_run {
        println!(
            "(simulation) {} élément(s) proposé(s), rien n'est écrit.",
            p.items.len()
        );
        return Ok(());
    }
    let n = ops::publish(paths, ch, p.items)?;
    println!("{n} élément(s) en attente dans {}", paths.press().display());
    println!("En jeu : /reload, puis Gazette > Rédaction pour publier ou ignorer.");
    Ok(())
}

fn set_config(cfg: &mut Config, key: &str, value: &str) -> Result<(), String> {
    let opt = |v: &str| (!v.trim().is_empty()).then(|| v.trim().to_string());
    let flag = |v: &str| match v {
        "true" | "oui" | "1" => Ok(true),
        "false" | "non" | "0" => Ok(false),
        _ => Err(format!("{key} : true ou false")),
    };
    match key {
        "wowPath" => cfg.wow_path = opt(value).map(PathBuf::from),
        "account" => cfg.account = opt(value),
        "rival" => cfg.rival = value.trim().to_string(),
        "articlesDir" => cfg.articles_dir = opt(value).map(PathBuf::from),
        "llmCommand" => {
            cfg.llm_command = serde_json::from_str(value).map_err(|e| {
                format!("llmCommand : liste JSON attendue, ex. [\"ssh\", \"pi5\", \"…\"] ({e})")
            })?
        }
        "llmTimeoutSecs" => {
            cfg.llm_timeout_secs = value.parse().map_err(|_| "llmTimeoutSecs : un nombre")?
        }
        "autoGazette" => cfg.auto_gazette = flag(value)?,
        "auto" => cfg.auto = flag(value)?,
        "testChannel" => cfg.test_channel = flag(value)?,
        _ => return Err(format!("réglage inconnu : {key}")),
    }
    Ok(())
}

fn articles_dir(cfg: &Config, arg: Option<&String>) -> Option<PathBuf> {
    arg.map(PathBuf::from).or_else(|| {
        cfg.articles_dir
            .as_ref()
            .map(|p| local_path(&p.to_string_lossy()))
    })
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let mut cfg = Config::load(&args.config);
    let cmd = args.rest.first().map(String::as_str).unwrap_or("help");
    let arg1 = args.rest.get(1);
    match cmd {
        "help" => println!("{HELP}"),
        "config" => {
            if let (Some(key), Some(value)) = (arg1, args.rest.get(2)) {
                set_config(&mut cfg, key, value)?;
                cfg.save(&args.config)?;
            }
            println!("{}", args.config.display());
            println!(
                "{}",
                serde_json::to_string_pretty(&cfg).map_err(|e| e.to_string())?
            );
        }
        "status" => {
            let p = paths(&args, &cfg)?;
            let st = ops::status(&p);
            println!("Dossier du jeu : {}", st.wow_path);
            println!(
                "Addons : Renatus {} ; Renatus_Admin {}",
                st.renatus_version.as_deref().unwrap_or("absent"),
                st.admin_version
                    .as_deref()
                    .unwrap_or("absent (renatus-admin install-admin)")
            );
            if let Some(e) = &st.error {
                println!("{e}");
                return Ok(());
            }
            println!(
                "Journal de l'addon : {}",
                st.saved_variables.as_deref().unwrap_or("?")
            );
            println!(
                "  {} événement(s), dont {} partagé(s) ; {} auteur(s)",
                st.events, st.shared, st.authors
            );
            println!("Journaux de combat : {}", st.combat_logs);
            println!(
                "Guilde rivale (réglage de guilde) : {}",
                st.configured_rival.as_deref().unwrap_or("aucune")
            );
            println!(
                "Avis de recherche ouverts : {}",
                if st.wanted.is_empty() {
                    "aucun".into()
                } else {
                    st.wanted.join(", ")
                }
            );
            println!("Presse en attente de validation en jeu : {}", st.pending);
        }
        "facts" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            let days: u32 = arg1.and_then(|d| d.parse().ok()).unwrap_or(7);
            let since = (ops::now() - i64::from(days) * 86400) as f64;
            let mut events: Vec<_> = ch
                .all()
                .filter(|e| {
                    str_of(e, "vis") == Some("G")
                        && num_of(e, "t") >= since
                        && str_of(e, "k") != Some("VOTE")
                })
                .collect();
            events.sort_by(|a, b| num_of(a, "t").total_cmp(&num_of(b, "t")));
            for (i, e) in events.iter().enumerate() {
                let when = chrono::DateTime::from_timestamp(num_of(e, "t") as i64, 0)
                    .map(|d| {
                        d.with_timezone(&chrono::Local)
                            .format("%d/%m %H:%M")
                            .to_string()
                    })
                    .unwrap_or_default();
                println!(
                    "{:3}. {when}  {} {}  [{}]  id={}",
                    i + 1,
                    str_of(e, "n").unwrap_or("?"),
                    str_of(e, "k").unwrap_or("?"),
                    str_of(e, "prov").unwrap_or("OBS"),
                    str_of(e, "id").unwrap_or("?")
                );
            }
            if events.is_empty() {
                println!("Aucun événement partagé sur les {days} derniers jours.");
            }
        }
        "deaths" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            let only = arg1.map(|f| local_path(f));
            publish(&p, &ch, ops::deaths(&p, &ch, only.as_deref()), args.dry_run)?;
        }
        "articles" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            let dir = articles_dir(&cfg, arg1)
                .ok_or("Indique le dossier des articles (renatus-admin articles <dossier>).")?;
            publish(&p, &ch, ops::articles(&dir, &ch), args.dry_run)?;
        }
        "gazette" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            if args.show {
                let b = ops::brief(&ch, 7, ops::now());
                print_notes(&ops::brief_summary(&b, ch.members().len()));
                println!(
                    "\n----- demande qui serait envoyée à l'IA -----\n{}",
                    gazette::prompt(&b)
                );
                return Ok(());
            }
            println!("Rédaction en cours (une ou deux minutes)…");
            let prop = ops::gazette(
                &ch,
                7,
                &cfg.llm_command,
                Duration::from_secs(cfg.llm_timeout_secs),
            );
            publish(&p, &ch, prop, args.dry_run)?;
        }
        "rival" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            let rival = arg1.cloned().unwrap_or_else(|| cfg.rival.clone());
            let (_, prop) = ops::rival(&rival, &ch)?;
            if arg1.is_some() && !args.dry_run {
                cfg.rival = rival;
            }
            cfg.last_armory = Some(ops::now());
            publish(&p, &ch, prop, args.dry_run)?;
            if !args.dry_run {
                cfg.save(&args.config)?;
            }
        }
        "run" => {
            let p = paths(&args, &cfg)?;
            let (_, ch) = ops::load(&p)?;
            let mut prop = ops::deaths(&p, &ch, None);
            if let Some(dir) = articles_dir(&cfg, None) {
                prop.extend(ops::articles(&dir, &ch));
            }
            let stale = cfg.last_armory.is_none_or(|t| ops::now() - t > 86400);
            if !cfg.rival.trim().is_empty() && stale {
                match ops::rival(&cfg.rival, &ch) {
                    Ok((_, r)) => {
                        prop.extend(r);
                        cfg.last_armory = Some(ops::now());
                    }
                    Err(e) => prop.notes.push(format!("Armurerie : {e}")),
                }
            }
            let edition = gazette::edition_key(ops::now() as f64);
            if cfg.auto_gazette && !ops::edition_done(&p, &ch, &edition) {
                prop.extend(ops::gazette(
                    &ch,
                    7,
                    &cfg.llm_command,
                    Duration::from_secs(cfg.llm_timeout_secs),
                ));
            }
            publish(&p, &ch, prop, args.dry_run)?;
            if !args.dry_run {
                cfg.save(&args.config)?;
            }
        }
        "install-admin" => {
            let p = paths(&args, &cfg)?;
            let release = addon::latest(cfg.test_channel)?
                .ok_or("Aucune release ne contient encore Renatus_Admin.")?;
            let before = addon::installed_version(&p.addons(), "Renatus_Admin");
            if before.as_deref() == Some(release.version.as_str()) {
                println!("Renatus_Admin {} est déjà installé.", release.version);
                return Ok(());
            }
            let bytes = addon::download(&release)?;
            let v = addon::install_zip(&p.addons(), &bytes)?;
            println!(
                "Renatus_Admin {v} installé dans {}. {}",
                p.addons().display(),
                if before.is_none() {
                    "Redémarre le jeu une fois."
                } else {
                    "En jeu : /reload"
                }
            );
        }
        other => return Err(format!("commande inconnue : {other}\n\n{HELP}")),
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
