//! Client for the Emberlight server (server/ in this repository).

use crate::records::{Notice, Proof, Removal, Removed, Reply};
use anyhow::{Context, Result, bail};
use reqwest::blocking::{Client as Http, RequestBuilder};
use reqwest::{StatusCode, Url};
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const MAX_UPLOAD: usize = 200;

#[derive(Debug, Deserialize)]
pub struct Character {
    pub name: String,
    pub officer: bool,
}

#[derive(Debug, Deserialize)]
pub struct Me {
    pub name: String,
    /// The Discord account's id. Optional: older servers do not send it.
    #[serde(default, rename = "discordId")]
    pub discord_id: Option<String>,
    #[serde(default)]
    pub officer: bool,
    #[serde(default)]
    pub realm: String,
    /// Verified characters, by addon identity.
    pub characters: Vec<Character>,
    pub scopes: Vec<String>,
    /// Party boards sync too (the server's test switch).
    #[serde(default, rename = "partyScopes")]
    pub party_scopes: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claim {
    pub id: i64,
    pub name: String,
    /// "pending", "verified" or "refused".
    pub status: String,
    pub method: Option<String>,
    pub created_at: i64,
}

#[derive(Debug, Deserialize)]
pub struct MyCharacters {
    pub realm: String,
    /// Every realm the guild plays on; one on Forever.
    #[serde(default)]
    pub realms: Vec<String>,
    pub characters: Vec<Claim>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingClaim {
    pub id: i64,
    pub name: String,
    pub member: String,
    pub created_at: i64,
    /// Other members waiting for the same character.
    pub competing: i64,
}

#[derive(Debug, Deserialize)]
pub struct UploadResult {
    pub scope: Option<String>,
    pub id: Option<String>,
    pub status: String,
    pub reason: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct Download {
    pub generated: i64,
    pub notices: Vec<Notice>,
    #[serde(default)]
    pub replies: Vec<Reply>,
    /// Notices an officer removed; servers before 5 October 2026 do not send it.
    #[serde(default)]
    pub removed: Vec<Removed>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Announcement {
    pub id: String,
    pub author: String,
    /// Discord markdown as posted, mentions already resolved to names by Warden.
    pub content: String,
    pub created_at: i64,
    pub edited_at: i64,
    pub url: String,
}

/// An event as `GET /v1/events` shapes it for reading: open, not withdrawn, and already there while
/// it is more than 21 days ahead (the game's sync download leaves those out).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GuildEvent {
    pub scope: String,
    pub id: String,
    /// `official`, or a member kind: `expedition`, `help` or `rp`.
    pub kind: String,
    pub title: String,
    #[serde(default)]
    pub location: Option<String>,
    #[serde(default)]
    pub body: String,
    pub start: i64,
    pub expires: i64,
    pub author: String,
    #[serde(default)]
    pub author_name: Option<String>,
    /// The signed-in member's own answers (website attendance; absent on older servers).
    #[serde(default)]
    pub own_replies: Vec<OwnReply>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OwnReply {
    pub response: String,
}

#[derive(Deserialize)]
struct ErrorBody {
    error: String,
}

pub struct Client {
    base: Url,
    token: String,
    http: Http,
}

/// HTTPS only, except for a server on this computer during development.
pub fn server_url(server: &str) -> Result<Url> {
    let url = Url::parse(server.trim_end_matches('/')).with_context(|| format!("'{server}' is not a web address"))?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        bail!("the server address must start with https://");
    }
    if !url.username().is_empty() || url.password().is_some() || url.query().is_some() {
        bail!("the server address must not contain a user name, password or query");
    }
    Ok(url)
}

/// Redeem a Discord sign-in grant for a session token. Returns (token, member name).
pub fn exchange_grant(server: &str, code: &str, verifier: &str) -> Result<(String, String)> {
    #[derive(Serialize)]
    struct Body<'a> {
        code: &'a str,
        verifier: &'a str,
    }
    #[derive(Deserialize)]
    struct Reply {
        token: String,
        name: String,
    }
    let base = server_url(server)?;
    let res = Http::builder()
        .timeout(Duration::from_secs(30))
        .user_agent(concat!("emberlight-sync/", env!("CARGO_PKG_VERSION")))
        .build()?
        .post(format!("{}/v1/auth/token", base.as_str().trim_end_matches('/')))
        .json(&Body { code, verifier })
        .send()
        .context("could not reach the Emberlight server")?;
    if !res.status().is_success() {
        bail!("the server did not accept the sign-in; try again");
    }
    let reply: Reply = res.json().context("the server sent an unexpected reply")?;
    Ok((reply.token, reply.name))
}

impl Client {
    pub fn new(server: &str, token: &str) -> Result<Self> {
        if !(32..=128).contains(&token.len()) || !token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
            bail!("the session token is not valid");
        }
        let http = Http::builder()
            .timeout(Duration::from_secs(30))
            .user_agent(concat!("emberlight-sync/", env!("CARGO_PKG_VERSION")))
            .build()?;
        Ok(Client { base: server_url(server)?, token: token.to_owned(), http })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base.as_str().trim_end_matches('/'), path)
    }

    fn request(&self, req: RequestBuilder) -> Result<reqwest::blocking::Response> {
        let res = req.bearer_auth(&self.token).send().context("could not reach the Emberlight server")?;
        let status = res.status();
        if status == StatusCode::UNAUTHORIZED {
            bail!("the server did not accept your sign-in; sign in again");
        }
        if !status.is_success() {
            // Server error messages are written for members and shown as they are.
            let message = res.json::<ErrorBody>().map(|e| e.error).unwrap_or_else(|_| format!("the server refused the request ({status})"));
            bail!("{message}");
        }
        Ok(res)
    }

    fn send<T: for<'de> Deserialize<'de>>(&self, req: RequestBuilder) -> Result<T> {
        self.request(req)?.json().context("the server sent an unexpected reply")
    }

    pub fn upload_replies(&self, replies: &[Reply]) -> Result<Vec<UploadResult>> {
        #[derive(Serialize)]
        struct Body<'a> {
            replies: &'a [Reply],
        }
        #[derive(Deserialize)]
        struct Reply2 {
            results: Vec<UploadResult>,
        }
        let mut out = Vec::new();
        for chunk in replies.chunks(MAX_UPLOAD) {
            let reply: Reply2 = self.send(self.http.post(self.url("/v1/replies")).json(&Body { replies: chunk }))?;
            out.extend(reply.results);
        }
        Ok(out)
    }

    /// Ends this session on the server, so the token stops working everywhere.
    pub fn logout(&self) -> Result<()> {
        self.request(self.http.post(self.url("/v1/auth/logout")))?;
        Ok(())
    }

    /// An officer's in-game removals; the server checks officer rights and hides the notices.
    pub fn upload_removals(&self, removals: &[Removal]) -> Result<Vec<UploadResult>> {
        #[derive(Serialize)]
        struct Body<'a> {
            removals: &'a [Removal],
        }
        #[derive(Deserialize)]
        struct Reply2 {
            results: Vec<UploadResult>,
        }
        let mut out = Vec::new();
        for chunk in removals.chunks(MAX_UPLOAD) {
            let reply: Reply2 = self.send(self.http.post(self.url("/v1/removals")).json(&Body { removals: chunk }))?;
            out.extend(reply.results);
        }
        Ok(out)
    }

    /// Character proofs this computer saw in game; the server matches them to waiting claims.
    pub fn upload_proofs(&self, proofs: &[Proof]) -> Result<Vec<UploadResult>> {
        #[derive(Serialize)]
        struct Body<'a> {
            proofs: &'a [Proof],
        }
        #[derive(Deserialize)]
        struct Reply2 {
            results: Vec<UploadResult>,
        }
        let mut out = Vec::new();
        for chunk in proofs.chunks(50) {
            let reply: Reply2 = self.send(self.http.post(self.url("/v1/characters/proofs")).json(&Body { proofs: chunk }))?;
            out.extend(reply.results);
        }
        Ok(out)
    }

    pub fn announcements(&self) -> Result<Vec<Announcement>> {
        #[derive(Deserialize)]
        struct Reply {
            announcements: Vec<Announcement>,
        }
        Ok(self.send::<Reply>(self.http.get(self.url("/v1/announcements")))?.announcements)
    }

    /// The guild's official events (`official`) or members' notices (`member`), soonest first.
    pub fn events(&self, kind: &str) -> Result<Vec<GuildEvent>> {
        #[derive(Deserialize)]
        struct Reply {
            events: Vec<GuildEvent>,
        }
        if kind != "official" && kind != "member" {
            bail!("unknown kind of event");
        }
        Ok(self.send::<Reply>(self.http.get(self.url(&format!("/v1/events?kind={kind}"))))?.events)
    }

    pub fn characters(&self) -> Result<MyCharacters> {
        self.send(self.http.get(self.url("/v1/characters")))
    }

    pub fn claim(&self, first_name: &str, surname: Option<&str>, realm: Option<&str>) -> Result<Claim> {
        #[derive(Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Body<'a> {
            first_name: &'a str,
            surname: Option<&'a str>,
            #[serde(skip_serializing_if = "Option::is_none")]
            realm: Option<&'a str>,
        }
        #[derive(Deserialize)]
        struct Reply {
            character: Claim,
        }
        let reply: Reply = self.send(self.http.post(self.url("/v1/characters")).json(&Body { first_name, surname, realm }))?;
        Ok(reply.character)
    }

    pub fn remove_character(&self, id: i64) -> Result<()> {
        self.request(self.http.delete(self.url(&format!("/v1/characters/{id}")))).map(|_| ())
    }

    pub fn pending_claims(&self) -> Result<Vec<PendingClaim>> {
        #[derive(Deserialize)]
        struct Reply {
            claims: Vec<PendingClaim>,
        }
        Ok(self.send::<Reply>(self.http.get(self.url("/v1/officer/claims")))?.claims)
    }

    pub fn decide_claim(&self, id: i64, approve: bool) -> Result<()> {
        #[derive(Serialize)]
        struct Body {
            approve: bool,
        }
        self.request(self.http.post(self.url(&format!("/v1/officer/claims/{id}"))).json(&Body { approve })).map(|_| ())
    }

    pub fn me(&self) -> Result<Me> {
        self.send(self.http.get(self.url("/v1/me")))
    }

    pub fn download(&self) -> Result<Download> {
        self.send(self.http.get(self.url("/v1/notices")))
    }

    pub fn upload(&self, notices: &[Notice]) -> Result<Vec<UploadResult>> {
        #[derive(Serialize)]
        struct Body<'a> {
            notices: &'a [Notice],
        }
        #[derive(Deserialize)]
        struct Reply {
            results: Vec<UploadResult>,
        }
        let mut out = Vec::new();
        for chunk in notices.chunks(MAX_UPLOAD) {
            let reply: Reply = self.send(self.http.post(self.url("/v1/notices")).json(&Body { notices: chunk }))?;
            out.extend(reply.results);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_or_local() {
        assert!(server_url("https://emberlight.example").is_ok());
        assert!(server_url("http://localhost:8787/").is_ok());
        assert!(server_url("http://127.0.0.1:8787").is_ok());
        assert!(server_url("http://emberlight.example").is_err());
        assert!(server_url("http://localhost.example.com").is_err());
        assert!(server_url("https://user:pw@emberlight.example").is_err());
        assert!(server_url("ftp://localhost").is_err());
        assert!(Client::new("https://emberlight.example", "short").is_err());
        assert!(Client::new("https://emberlight.example", &"a".repeat(40)).is_ok());
    }
}
