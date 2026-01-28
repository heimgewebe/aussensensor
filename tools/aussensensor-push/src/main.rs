use anyhow::{bail, Context, Result};
use clap::Parser;
use std::fs::File;
use std::io::{BufRead, BufReader, ErrorKind, Read, Seek, SeekFrom};

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

// Pass 1: Scan, Validate (Heuristic), and Count
fn scan_and_validate(file: &mut File) -> Result<usize> {
    let mut count = 0;
    // Use a BufReader wrapper around the mutable reference to the file.
    // This allows us to read the file without consuming the handle.
    for (i, line) in BufReader::new(file).lines().enumerate() {
        let l = line?;
        if l.trim().is_empty() {
            continue;
        }
        // einfache Hygiene: jede Zeile muss ein JSON-Objekt sein (heuristisch)
        if !(l.trim_start().starts_with('{') && l.trim_end().ends_with('}')) {
            bail!("Zeile {}: keine JSON-Objekt-Zeile: {}", i + 1, l);
        }
        count += 1;
    }
    Ok(count)
}

struct JsonlReader<R> {
    reader: BufReader<R>,
    buffer: Vec<u8>,
    cursor: usize,
    line_buf: String,
    line_number: usize,
}

impl<R: Read> JsonlReader<R> {
    fn new(inner: R) -> Self {
        Self {
            reader: BufReader::new(inner),
            buffer: Vec::new(),
            cursor: 0,
            line_buf: String::new(),
            line_number: 0,
        }
    }
}

impl<R: Read> Read for JsonlReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        // Optimization: No-op for empty buffer probes
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
            self.line_number += 1;

            // Skip empty lines (whitespace only)
            if self.line_buf.trim().is_empty() {
                continue;
            }

            // Consistency Check: Ensure line matches the Pass 1 heuristic.
            // Since we reused the file handle, this should theoretically never fail
            // unless the filesystem was tampered with underneath, but it guarantees safety.
            if !(self.line_buf.trim_start().starts_with('{')
                && self.line_buf.trim_end().ends_with('}'))
            {
                return Err(std::io::Error::new(
                    ErrorKind::InvalidData,
                    format!(
                        "Zeile {}: keine JSON-Objekt-Zeile: {}",
                        self.line_number, self.line_buf
                    ),
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

    // Open file once
    let mut f = File::open(&args.file).with_context(|| format!("open {}", &args.file))?;

    // Pass 1: Validate and count
    let count = scan_and_validate(&mut f)?;

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

    // Reset file cursor to beginning for Pass 2
    f.seek(SeekFrom::Start(0))
        .context("failed to rewind file")?;

    // Pass 2: Stream using the same file handle
    let reader = JsonlReader::new(f);

    let client = reqwest::blocking::Client::new();
    let mut req = client
        .post(&args.url)
        .header(reqwest::header::CONTENT_TYPE, "application/x-ndjson");
    if let Some(t) = &token {
        req = req.header("x-auth", t);
    }

    // Uses Transfer-Encoding: chunked
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
