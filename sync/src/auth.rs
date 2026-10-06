//! Discord sign-in from a desktop app, the app's half (see server/src/auth.ts for the other).
//!
//! The app picks a PKCE verifier and a state, listens on 127.0.0.1, and opens the browser at the
//! server's start URL. The server sends the browser back to the loopback with a one-time grant,
//! which only this app can redeem because only it knows the verifier.

use anyhow::{Result, bail};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use reqwest::Url;
use sha2::{Digest, Sha256};
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub fn random_token() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("operating system random numbers");
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

impl Pkce {
    pub fn new() -> Self {
        let verifier = random_token();
        Pkce { challenge: challenge(&verifier), verifier }
    }
}

impl Default for Pkce {
    fn default() -> Self {
        Self::new()
    }
}

pub fn start_url(server: &Url, port: u16, state: &str, challenge: &str) -> String {
    let mut url = server.join("/v1/auth/discord/start").expect("fixed path");
    url.query_pairs_mut()
        .append_pair("port", &port.to_string())
        .append_pair("state", state)
        .append_pair("challenge", challenge);
    url.to_string()
}

const DONE_PAGE: &str = "Signed in. You can close this tab and return to Emberlight.";
const RETRY_PAGE: &str = "Sign-in did not finish. Return to Emberlight and try again.";

fn respond(stream: &mut TcpStream, status: &str, message: &str) {
    let body = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Emberlight</title><style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#070b16;color:#e9e1cc;font:17px/1.5 Georgia,serif}}p{{max-width:28rem;padding:2rem;border:1px solid #8a6c2e;background:#0d1530;text-align:center}}</style></head><body><p>{message}</p></body></html>"
    );
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

/// A one-shot listener on 127.0.0.1 for the browser's return from the server.
pub struct Loopback {
    listener: TcpListener,
}

impl Loopback {
    pub fn bind() -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0))?;
        listener.set_nonblocking(true)?;
        Ok(Loopback { listener })
    }

    pub fn port(&self) -> u16 {
        self.listener.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Wait for `/callback?code=..&state=..` with the expected state and return the grant.
    /// Other requests (a browser asking for a favicon) are answered and ignored.
    pub fn wait(&self, state: &str, timeout: Duration, cancel: &AtomicBool) -> Result<String> {
        let deadline = Instant::now() + timeout;
        loop {
            if cancel.load(Ordering::SeqCst) {
                bail!("Sign-in was cancelled.");
            }
            if Instant::now() > deadline {
                bail!("Sign-in timed out. Try again.");
            }
            match self.listener.accept() {
                Ok((mut stream, _)) => {
                    if let Some(result) = Self::handle(&mut stream, state) {
                        return result;
                    }
                }
                Err(e) if e.kind() == ErrorKind::WouldBlock => std::thread::sleep(Duration::from_millis(150)),
                Err(e) => return Err(e.into()),
            }
        }
    }

    fn handle(stream: &mut TcpStream, state: &str) -> Option<Result<String>> {
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut buf = [0u8; 4096];
        let mut len = 0;
        while len < buf.len() {
            match stream.read(&mut buf[len..]) {
                Ok(0) => break,
                Ok(n) => {
                    len += n;
                    if buf[..len].windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        let request = String::from_utf8_lossy(&buf[..len]);
        let target = request.lines().next().and_then(|line| {
            let mut parts = line.split(' ');
            (parts.next() == Some("GET")).then(|| parts.next()).flatten()
        });
        let Some(url) = target.and_then(|t| Url::parse(&format!("http://127.0.0.1{t}")).ok()) else {
            respond(stream, "400 Bad Request", RETRY_PAGE);
            return None;
        };
        if url.path() != "/callback" {
            respond(stream, "404 Not Found", RETRY_PAGE);
            return None;
        }
        let get = |k: &str| url.query_pairs().find(|(key, _)| key == k).map(|(_, v)| v.into_owned());
        let code = get("code").filter(|c| c.len() == 43 && c.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
        match (code, get("state")) {
            (Some(code), Some(s)) if s == state => {
                respond(stream, "200 OK", DONE_PAGE);
                Some(Ok(code))
            }
            _ => {
                respond(stream, "400 Bad Request", RETRY_PAGE);
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn pkce_matches_server_rule() {
        // Same pair is asserted in server/test/auth.test.ts (checked independently with Python).
        assert_eq!(challenge("dBjftJeZ4CVP-mJ0kjchl2vrrT9eQM5rSRj9Cx2SQMo"), "z-ArMc7lh70Lyw1GOBKfGbEwMjyTL-pPyliwHXLPbhU");
        let p = Pkce::new();
        assert_eq!(p.verifier.len(), 43);
        assert_ne!(Pkce::new().verifier, p.verifier);
    }

    #[test]
    fn start_url_is_on_the_server() {
        let url = start_url(&Url::parse("https://emberlight.example/").unwrap(), 45678, "st", "ch");
        assert_eq!(url, "https://emberlight.example/v1/auth/discord/start?port=45678&state=st&challenge=ch");
    }

    fn get(port: u16, path: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(s, "GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        out
    }

    #[test]
    fn loopback_accepts_only_the_matching_state() {
        let lb = Loopback::bind().unwrap();
        let port = lb.port();
        let code = "c".repeat(43);
        let expected = code.clone();
        let browser = std::thread::spawn(move || {
            let favicon = get(port, "/favicon.ico");
            let wrong = get(port, &format!("/callback?code={code}&state=other"));
            let ok = get(port, &format!("/callback?code={code}&state=mine"));
            (favicon, wrong, ok)
        });
        let got = lb.wait("mine", Duration::from_secs(10), &AtomicBool::new(false)).unwrap();
        let (favicon, wrong, ok) = browser.join().unwrap();
        assert_eq!(got, expected);
        assert!(favicon.starts_with("HTTP/1.1 404"));
        assert!(wrong.starts_with("HTTP/1.1 400"));
        assert!(ok.starts_with("HTTP/1.1 200") && ok.contains("return to Emberlight"));
    }

    #[test]
    fn loopback_can_be_cancelled() {
        let lb = Loopback::bind().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            flag.store(true, Ordering::SeqCst);
        });
        let err = lb.wait("x", Duration::from_secs(10), &cancel).unwrap_err();
        assert!(err.to_string().contains("cancelled"));
    }
}
