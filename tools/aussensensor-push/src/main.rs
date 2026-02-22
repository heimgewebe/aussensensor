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

/// Heuristische Prüfung: jede Zeile muss wie ein JSON-Objekt aussehen.
/// Dies ist keine vollständige JSON-Validierung, sondern dient der grundlegenden Hygiene.
fn looks_like_json_object_line(line: &str) -> bool {
    line.trim_start().starts_with('{') && line.trim_end().ends_with('}')
}

// Pass 1: Scan, Validate (Heuristic), and Count
fn scan_and_validate(file: &mut File) -> Result<usize> {
    let mut count = 0;
    let mut reader = BufReader::new(file);
    let mut line_buf = String::new();
    let mut line_num = 0;

    // Optimization: reuse String buffer to avoid allocation per line
    loop {
        line_buf.clear();
        let n = reader.read_line(&mut line_buf)?;
        if n == 0 {
            break;
        }
        line_num += 1;

        let trimmed = line_buf.trim();
        if trimmed.is_empty() {
            continue;
        }

        if !looks_like_json_object_line(trimmed) {
            bail!("Zeile {}: keine JSON-Objekt-Zeile: {}", line_num, trimmed);
        }
        count += 1;
    }
    Ok(count)
}

struct JsonlReader<R> {
    reader: BufReader<R>,
    cursor: usize,
    line_buf: String,
    line_number: usize,
}

impl<R: Read> JsonlReader<R> {
    fn new(inner: R) -> Self {
        Self {
            reader: BufReader::new(inner),
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

        if self.cursor >= self.line_buf.len() {
            self.line_buf.clear();
            self.cursor = 0;

            loop {
                // read_line reads until newline, including it.
                let n = self.reader.read_line(&mut self.line_buf)?;
                if n == 0 {
                    return Ok(0); // EOF
                }
                self.line_number += 1;

                // Skip empty lines (whitespace only)
                if self.line_buf.trim().is_empty() {
                    self.line_buf.clear();
                    continue;
                }

                // Consistency Check: Ensure line matches the Pass 1 heuristic.
                if !looks_like_json_object_line(&self.line_buf) {
                    return Err(std::io::Error::new(
                        ErrorKind::InvalidData,
                        format!(
                            "Zeile {}: keine JSON-Objekt-Zeile: {}",
                            self.line_number,
                            self.line_buf.trim_end()
                        ),
                    ));
                }

                // Normalize line ending to \n in-place
                // Remove existing newline chars from the end
                if self.line_buf.ends_with('\n') {
                    self.line_buf.pop();
                    if self.line_buf.ends_with('\r') {
                        self.line_buf.pop();
                    }
                }
                self.line_buf.push('\n');
                break;
            }
        }

        let remaining = &self.line_buf.as_bytes()[self.cursor..];
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
        eprintln!("[DRY-RUN] Würde {} Events an {} senden.", count, &args.url);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_looks_like_json_object_line() {
        assert!(looks_like_json_object_line(r#"{"id":1}"#));
        assert!(looks_like_json_object_line(r#"  {"id":1}  "#));
        assert!(!looks_like_json_object_line(r#"not json"#));
        assert!(!looks_like_json_object_line(r#"{"id":1"#));
    }

    #[test]
    fn test_jsonl_reader_streaming() {
        let input = "{\"a\":1}\n\n{\"b\":2}\n";
        let cursor = Cursor::new(input);
        let mut reader = JsonlReader::new(cursor);
        let mut output = String::new();
        reader.read_to_string(&mut output).unwrap();
        // Expect clean NDJSON with no empty lines
        assert_eq!(output, "{\"a\":1}\n{\"b\":2}\n");
    }

    #[test]
    fn test_jsonl_reader_invalid_data() {
        let input = "{\"a\":1}\ngarbage\n";
        let cursor = Cursor::new(input);
        let mut reader = JsonlReader::new(cursor);
        let mut output = String::new();
        let err = reader.read_to_string(&mut output).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::InvalidData);
        assert!(err.to_string().contains("Zeile 2"));
        assert!(err.to_string().contains("garbage"));
        // Ensure newlines are trimmed from error message
        assert!(!err.to_string().contains("garbage\n"));
    }

    #[test]
    fn test_jsonl_reader_empty_buf_probe() {
        let input = "{\"a\":1}\n";
        let cursor = Cursor::new(input);
        let mut reader = JsonlReader::new(cursor);
        let mut buf = [0u8; 0];
        // Must return Ok(0)
        let n = reader.read(&mut buf).unwrap();
        assert_eq!(n, 0);
        // Ensure nothing was consumed
        let mut output = String::new();
        reader.read_to_string(&mut output).unwrap();
        assert_eq!(output, "{\"a\":1}\n");
    }
}
