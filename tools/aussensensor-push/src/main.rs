use anyhow::{bail, Context, Result};
use clap::Parser;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, ErrorKind, Read};

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

fn scan_and_validate(path: &str) -> Result<(usize, fs::Metadata)> {
    let f = File::open(path).with_context(|| format!("open {}", path))?;
    let metadata = f.metadata().context("failed to read file metadata")?;
    let mut count = 0;
    for line in BufReader::new(f).lines() {
        let l = line?;
        if l.trim().is_empty() {
            continue;
        }
        // einfache Hygiene: jede Zeile muss ein JSON-Objekt sein (heuristisch)
        if !(l.trim_start().starts_with('{') && l.trim_end().ends_with('}')) {
            bail!("keine JSON-Objekt-Zeile: {}", l);
        }
        count += 1;
    }
    Ok((count, metadata))
}

struct JsonlReader<R> {
    reader: BufReader<R>,
    buffer: Vec<u8>,
    cursor: usize,
    line_buf: String,
}

impl<R: Read> JsonlReader<R> {
    fn new(inner: R) -> Self {
        Self {
            reader: BufReader::new(inner),
            buffer: Vec::new(),
            cursor: 0,
            line_buf: String::new(),
        }
    }
}

impl<R: Read> Read for JsonlReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        while self.cursor >= self.buffer.len() {
            self.buffer.clear();
            self.cursor = 0;
            self.line_buf.clear();

            // read_line reads until newline, including it.
            let n = self.reader.read_line(&mut self.line_buf)?;
            if n == 0 {
                return Ok(0); // EOF
            }

            // Skip empty lines (whitespace only)
            if self.line_buf.trim().is_empty() {
                continue;
            }

            // Consistency check: must look like JSON object
            // This mirrors scan_and_validate logic to ensure we don't send unvalidated data
            if !(self.line_buf.trim_start().starts_with('{')
                && self.line_buf.trim_end().ends_with('}'))
            {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!("keine JSON-Objekt-Zeile: {}", self.line_buf),
                ));
            }

            // Normalize line ending to \n
            // Remove existing newline chars from the end
            if self.line_buf.ends_with('\n') {
                self.line_buf.pop();
                if self.line_buf.ends_with('\r') {
                    self.line_buf.pop();
                }
            }

            self.buffer.extend_from_slice(self.line_buf.as_bytes());
            self.buffer.push(b'\n');
        }

        let remaining = &self.buffer[self.cursor..];
        let to_copy = std::cmp::min(remaining.len(), buf.len());
        buf[..to_copy].copy_from_slice(&remaining[..to_copy]);
        self.cursor += to_copy;
        Ok(to_copy)
    }
}

fn main() -> Result<()> {
    let args = Args::parse();

    // Pass 1: Validate and count
    let (count, meta_before) = scan_and_validate(&args.file)?;

    if count == 0 {
        eprintln!("Warnung: keine Events in {}", &args.file);
        return Ok(());
    }

    // Token aus Environment lesen
    let token = std::env::var("CHRONIK_TOKEN").ok();

    if args.dry_run {
        eprintln!(
            "[DRY-RUN] Würde {} Events an {} senden.",
            count, &args.url
        );
        if let Some(t) = &token {
            eprintln!("[DRY-RUN] Token: gesetzt ({} Zeichen).", t.len());
        } else {
            eprintln!("[DRY-RUN] Token: nicht gesetzt.");
        }
        return Ok(());
    }

    // TOCTOU Check
    let f = File::open(&args.file).with_context(|| format!("open {}", &args.file))?;
    let meta_after = f.metadata().context("failed to read file metadata (pass 2)")?;

    if meta_before.len() != meta_after.len()
        || meta_before.modified().ok() != meta_after.modified().ok()
    {
        bail!("file changed during run: {}", args.file);
    }

    // Pass 2: Stream
    let reader = JsonlReader::new(f);

    let client = reqwest::blocking::Client::new();
    let mut req = client
        .post(&args.url)
        .header(reqwest::header::CONTENT_TYPE, "application/x-ndjson");
    if let Some(t) = &token {
        req = req.header("x-auth", t);
    }

    // reqwest Body handles Reader and uses Transfer-Encoding: chunked if needed
    // or we can set Content-Length if we calculated it, but we only calculated line count.
    // Calculating exact byte size in Pass 1 is possible but maybe overkill/complex if line endings change.
    // Chunked is fine for NDJSON.
    let resp = req
        .body(reqwest::blocking::Body::new(reader))
        .send()
        .with_context(|| format!("POST {}", &args.url))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp
            .text()
            .unwrap_or_else(|err| format!("<Fehler beim Lesen des Antwortbodys: {err}>"));

        bail!("ingest failed: {status} - response body: {body}");
    }

    // Success: Output the response body to stdout (as curl does)
    let resp_body = resp.text().context("failed to read response body")?;
    print!("{}", resp_body);

    // Ensure trailing newline if missing and body not empty
    if !resp_body.is_empty() && !resp_body.ends_with('\n') {
        println!();
    }

    eprintln!("OK: {} akzeptiert", args.url);
    Ok(())
}
