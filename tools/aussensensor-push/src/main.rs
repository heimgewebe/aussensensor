use anyhow::{bail, Context, Result};
use clap::Parser;
use std::fs::File;
use std::io::{BufRead, BufReader};

/// Send NDJSON to chronik /v1/ingest
#[derive(Parser, Debug)]
struct Args {
    /// Base URL incl. /v1/ingest
    #[arg(long)]
    url: String,
    /// Path to .jsonl (NDJSON)
    #[arg(long)]
    file: String,
    /// Dry run
    #[arg(long)]
    dry_run: bool,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let f = File::open(&args.file).with_context(|| format!("open {}", &args.file))?;
    let mut lines = Vec::new();
    for line in BufReader::new(f).lines() {
        let l = line?;
        if l.trim().is_empty() { continue; }
        // einfache Hygiene: jede Zeile muss ein JSON-Objekt sein (heuristisch)
        if !(l.trim_start().starts_with('{') && l.trim_end().ends_with('}')) {
            bail!("keine JSON-Objekt-Zeile: {}", l);
        }
        lines.push(l);
    }
    if lines.is_empty() {
        println!("Warnung: keine Events in {}", &args.file);
        return Ok(());
    }

    // Token aus Environment lesen
    let token = std::env::var("CHRONIK_TOKEN").ok();

    if args.dry_run {
        println!("[DRY-RUN] Würde {} Events an {} senden.", lines.len(), &args.url);
        if let Some(t) = &token {
            println!("[DRY-RUN] Token: gesetzt ({} Zeichen).", t.len());
        } else {
            println!("[DRY-RUN] Token: nicht gesetzt.");
        }
        return Ok(());
    }
    let body = lines.join("\n") + "\n";
    let client = reqwest::blocking::Client::new();
    let mut req = client
        .post(&args.url)
        .header(reqwest::header::CONTENT_TYPE, "application/x-ndjson");
    if let Some(t) = &token {
        req = req.header("x-auth", t);
    }
    let resp = req
        .body(body)
        .send()
        .with_context(|| format!("POST {}", &args.url))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp
            .text()
            .unwrap_or_else(|err| format!("<Fehler beim Lesen des Antwortbodys: {err}>"));

        bail!("ingest failed: {status} - response body: {body}");
    }
    println!("OK: {} akzeptiert", args.url);
    Ok(())
}
