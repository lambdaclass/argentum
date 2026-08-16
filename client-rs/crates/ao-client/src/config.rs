//! Where the client gets its endpoints and, for now, its credentials.
//!
//! Nothing here may be a compiled-in production host or credential. In the
//! browser the endpoints are derived from the page origin, which is correct by
//! construction once the client is served from the game origin: a page loaded
//! over HTTPS talks WSS to the same host, and there is nothing to update when
//! the deployment moves.
//!
//! Development does not have that property yet — the dev server serves HTTP on
//! 4000, the gateway listens on 7667, and the page is often served from a third
//! port — so overrides are explicit and layered:
//!
//! 1. query string (`?gateway=ws://host:7667/ao`) — per-load, no file to edit
//! 2. `<meta name="ao:gateway-url" content="...">` in the host page
//! 3. derived from the page origin
//!
//! The host page is not the client binary. Keeping dev values there is what
//! lets the wasm artifact stay free of hosts and credentials.
//!
//! Resolution is pure so it can be tested without a browser; the platform
//! layers only supply strings.

/// Where the page was served from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Origin {
    /// True for `https:`/`wss:`. Decides whether the socket is `ws` or `wss` —
    /// a secure page cannot open an insecure socket, and getting this wrong
    /// produces a browser-level block rather than a connection error.
    pub secure: bool,
    /// Host and port as the page reports them, e.g. `play.example.com` or
    /// `127.0.0.1:8080`.
    pub host: String,
}

/// One layer of explicit configuration. Absent fields defer to the next layer.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Overrides {
    pub asset_origin: Option<String>,
    pub gateway_url: Option<String>,
    pub character_name: Option<String>,
    pub character_password: Option<String>,
    pub client_hash: Option<String>,
}

/// Credentials for the placeholder auto-login.
///
/// Temporary: it exists because there is no login screen yet. It is
/// deliberately an `Option` on the config rather than a default, so that a
/// client with nothing configured does not silently create a character.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Credentials {
    pub name: String,
    pub password: String,
}

/// Resolved endpoints for this run.
#[derive(Debug, Clone, PartialEq, Eq, bevy::prelude::Resource)]
pub struct ClientConfig {
    /// Origin for world data and status endpoints, without a trailing slash.
    pub asset_origin: String,
    pub gateway_url: String,
    /// None means "do not auto-connect": no credentials were configured.
    pub credentials: Option<Credentials>,
    /// Build identifier the server records. Not a secret and not a host, so it
    /// is the one value that may have a compiled-in default.
    pub client_hash: String,
}

/// Default when no layer supplies one.
const DEFAULT_CLIENT_HASH: &str = "rust-client";

/// Path the gateway listens on. Shared with the web client.
const GATEWAY_PATH: &str = "/ao";

fn first<'a>(layers: &'a [Overrides], pick: fn(&Overrides) -> Option<&String>) -> Option<&'a str> {
    layers.iter().find_map(|layer| pick(layer).map(String::as_str))
}

/// Combine layers, highest precedence first, over an optional page origin.
///
/// `origin` is `None` on native, which has no page to derive from; there every
/// endpoint must come from a layer, and the caller supplies development
/// defaults rather than this module inventing them.
pub fn resolve(origin: Option<&Origin>, layers: &[Overrides]) -> Option<ClientConfig> {
    let asset_origin = first(layers, |o| o.asset_origin.as_ref())
        .map(trim_trailing_slash)
        .map(str::to_owned)
        .or_else(|| origin.map(derive_asset_origin))?;

    let gateway_url = first(layers, |o| o.gateway_url.as_ref())
        .map(str::to_owned)
        .or_else(|| origin.map(derive_gateway_url))?;

    // Both halves must be present. A name with no password would fail login in
    // a way that looks like a server problem.
    let credentials = match (
        first(layers, |o| o.character_name.as_ref()),
        first(layers, |o| o.character_password.as_ref()),
    ) {
        (Some(name), Some(password)) if !name.is_empty() && !password.is_empty() => {
            Some(Credentials { name: name.to_owned(), password: password.to_owned() })
        }
        _ => None,
    };

    let client_hash =
        first(layers, |o| o.client_hash.as_ref()).unwrap_or(DEFAULT_CLIENT_HASH).to_owned();

    Some(ClientConfig { asset_origin, gateway_url, credentials, client_hash })
}

fn trim_trailing_slash(value: &str) -> &str {
    value.strip_suffix('/').unwrap_or(value)
}

fn derive_asset_origin(origin: &Origin) -> String {
    let scheme = if origin.secure { "https" } else { "http" };
    format!("{scheme}://{}", origin.host)
}

fn derive_gateway_url(origin: &Origin) -> String {
    let scheme = if origin.secure { "wss" } else { "ws" };
    format!("{scheme}://{}{GATEWAY_PATH}", origin.host)
}

/// Read overrides from a query string, with or without a leading `?`.
///
/// Values are percent-decoded, so a gateway URL can be passed whole:
/// `?gateway=ws%3A%2F%2F127.0.0.1%3A7667%2Fao`. Unknown keys are ignored
/// rather than rejected — the page may carry query parameters that have
/// nothing to do with the client.
pub fn parse_query(query: &str) -> Overrides {
    let mut overrides = Overrides::default();

    for pair in query.trim_start_matches('?').split('&') {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let value = percent_decode(value);
        if value.is_empty() {
            continue;
        }

        match key {
            "server" => overrides.asset_origin = Some(value),
            "gateway" => overrides.gateway_url = Some(value),
            "name" => overrides.character_name = Some(value),
            "password" => overrides.character_password = Some(value),
            "hash" => overrides.client_hash = Some(value),
            _ => {}
        }
    }

    overrides
}

/// Decode `%XX` escapes and `+`.
///
/// Hand-rolled to avoid pulling a dependency into the wasm payload for one
/// function. An invalid escape is left as written rather than dropped, so a
/// malformed URL produces a visibly wrong endpoint instead of a subtly
/// truncated one.
fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;

    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            // Decoded from the raw bytes, never by slicing the &str: `%` may be
            // followed by a multi-byte character, and slicing at i+1..i+3 would
            // land inside it and panic.
            b'%' if i + 2 < bytes.len() => {
                let hi = (bytes[i + 1] as char).to_digit(16);
                let lo = (bytes[i + 2] as char).to_digit(16);
                match (hi, lo) {
                    (Some(hi), Some(lo)) => {
                        out.push((hi * 16 + lo) as u8);
                        i += 3;
                    }
                    _ => {
                        out.push(b'%');
                        i += 1;
                    }
                }
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }

    String::from_utf8_lossy(&out).into_owned()
}

/// Keys read from `<meta name="..." content="...">` in the host page.
#[cfg(target_arch = "wasm32")]
const META_KEYS: [(&str, fn(&mut Overrides, String)); 5] = [
    ("ao:asset-origin", |o, v| o.asset_origin = Some(v)),
    ("ao:gateway-url", |o, v| o.gateway_url = Some(v)),
    ("ao:character-name", |o, v| o.character_name = Some(v)),
    ("ao:character-password", |o, v| o.character_password = Some(v)),
    ("ao:client-hash", |o, v| o.client_hash = Some(v)),
];

/// Resolve configuration from the browser: query string, then page meta tags,
/// then the page origin itself.
#[cfg(target_arch = "wasm32")]
pub fn load() -> Option<ClientConfig> {
    let window = web_sys::window()?;
    let location = window.location();

    let origin = match (location.protocol(), location.host()) {
        (Ok(protocol), Ok(host)) if !host.is_empty() => {
            Some(Origin { secure: protocol.starts_with("https"), host })
        }
        // A page opened from file:// has no host to derive from. Explicit
        // configuration is then the only option, and saying so beats deriving
        // an endpoint from an empty string.
        _ => None,
    };

    let query = location.search().map(|q| parse_query(&q)).unwrap_or_default();
    let meta = window.document().map(read_meta_tags).unwrap_or_default();

    resolve(origin.as_ref(), &[query, meta])
}

#[cfg(target_arch = "wasm32")]
fn read_meta_tags(document: web_sys::Document) -> Overrides {
    let mut overrides = Overrides::default();

    for (name, apply) in META_KEYS {
        let value = document
            .query_selector(&format!("meta[name=\"{name}\"]"))
            .ok()
            .flatten()
            .and_then(|element| element.get_attribute("content"))
            .filter(|content| !content.is_empty());

        if let Some(value) = value {
            apply(&mut overrides, value);
        }
    }

    overrides
}

/// Resolve configuration from the environment.
///
/// Native has no page origin, so every endpoint must be given. Returning None
/// when they are not is what keeps a host out of the binary: there is no
/// fallback to fall back to.
#[cfg(not(target_arch = "wasm32"))]
pub fn load() -> Option<ClientConfig> {
    let from_env = Overrides {
        asset_origin: std::env::var("AO_ASSET_ORIGIN").ok(),
        gateway_url: std::env::var("AO_GATEWAY_URL").ok(),
        character_name: std::env::var("AO_CHARACTER_NAME").ok(),
        character_password: std::env::var("AO_CHARACTER_PASSWORD").ok(),
        client_hash: std::env::var("AO_CLIENT_HASH").ok(),
    };

    resolve(None, &[from_env])
}

/// What to tell someone whose client has nowhere to connect to.
pub const MISSING_CONFIG_HELP: &str = concat!(
    "no endpoints configured. In the browser, serve the client from the game ",
    "origin or set <meta name=\"ao:gateway-url\" content=\"ws://host:7667/ao\">; ",
    "natively, set AO_ASSET_ORIGIN and AO_GATEWAY_URL.",
);

/// What to tell someone whose client is configured but has no character.
pub const MISSING_CREDENTIALS_HELP: &str = concat!(
    "no credentials configured, so the client will not log in. Until there is ",
    "a login screen, pass ?name=...&password=... or set the ao:character-name ",
    "and ao:character-password meta tags.",
);

#[cfg(test)]
mod tests {
    use super::*;

    fn origin(secure: bool, host: &str) -> Origin {
        Origin { secure, host: host.to_owned() }
    }

    #[test]
    fn a_plain_page_derives_both_endpoints_from_its_own_origin() {
        let config = resolve(Some(&origin(false, "127.0.0.1:4000")), &[]).unwrap();

        assert_eq!(config.asset_origin, "http://127.0.0.1:4000");
        assert_eq!(config.gateway_url, "ws://127.0.0.1:4000/ao");
    }

    #[test]
    fn a_secure_page_uses_a_secure_socket() {
        // A page served over HTTPS cannot open a ws:// socket: the browser
        // blocks it outright, which does not look like a connection failure.
        let config = resolve(Some(&origin(true, "play.example.com")), &[]).unwrap();

        assert_eq!(config.asset_origin, "https://play.example.com");
        assert_eq!(config.gateway_url, "wss://play.example.com/ao");
    }

    #[test]
    fn no_host_is_compiled_in_so_native_needs_explicit_configuration() {
        // Native has no page to derive from. Returning None is what makes a
        // missing configuration a visible startup failure rather than a
        // connection attempt against a host baked into the binary.
        assert!(resolve(None, &[]).is_none());
        assert!(resolve(None, &[Overrides { asset_origin: Some("http://h".into()), ..default() }])
            .is_none());
    }

    fn default() -> Overrides {
        Overrides::default()
    }

    #[test]
    fn explicit_configuration_beats_the_page_origin() {
        let layers = [Overrides {
            asset_origin: Some("http://127.0.0.1:4000".into()),
            gateway_url: Some("ws://127.0.0.1:7667/ao".into()),
            ..default()
        }];
        let config = resolve(Some(&origin(false, "localhost:8080")), &layers).unwrap();

        // The dev layout: page on one port, API on another, gateway on a third.
        assert_eq!(config.asset_origin, "http://127.0.0.1:4000");
        assert_eq!(config.gateway_url, "ws://127.0.0.1:7667/ao");
    }

    #[test]
    fn earlier_layers_win_field_by_field() {
        let query = Overrides { gateway_url: Some("ws://from-query/ao".into()), ..default() };
        let page = Overrides {
            gateway_url: Some("ws://from-page/ao".into()),
            asset_origin: Some("http://from-page".into()),
            ..default()
        };
        let config = resolve(Some(&origin(false, "ignored")), &[query, page]).unwrap();

        // A query override of one field must not discard the page's others.
        assert_eq!(config.gateway_url, "ws://from-query/ao");
        assert_eq!(config.asset_origin, "http://from-page");
    }

    #[test]
    fn a_trailing_slash_on_the_asset_origin_does_not_produce_a_double_slash() {
        let layers = [Overrides { asset_origin: Some("http://host:4000/".into()), ..default() }];
        let config = resolve(Some(&origin(false, "h")), &layers).unwrap();

        assert_eq!(config.asset_origin, "http://host:4000");
    }

    #[test]
    fn without_credentials_the_client_does_not_auto_connect() {
        // No compiled-in character. Connecting anyway would create one on the
        // server for anybody who loads the page.
        let config = resolve(Some(&origin(false, "h")), &[]).unwrap();
        assert_eq!(config.credentials, None);
    }

    #[test]
    fn half_a_credential_is_not_a_credential() {
        for layer in [
            Overrides { character_name: Some("Someone".into()), ..default() },
            Overrides { character_password: Some("secret".into()), ..default() },
            Overrides {
                character_name: Some("".into()),
                character_password: Some("secret".into()),
                ..default()
            },
        ] {
            let config = resolve(Some(&origin(false, "h")), &[layer]).unwrap();
            assert_eq!(config.credentials, None, "a partial credential must not be used");
        }
    }

    #[test]
    fn both_halves_present_enables_auto_connect() {
        let layers = [Overrides {
            character_name: Some("RustClient".into()),
            character_password: Some("pass".into()),
            ..default()
        }];
        let config = resolve(Some(&origin(false, "h")), &layers).unwrap();

        assert_eq!(
            config.credentials,
            Some(Credentials { name: "RustClient".into(), password: "pass".into() })
        );
    }

    #[test]
    fn the_client_hash_has_a_default_because_it_is_neither_host_nor_secret() {
        let config = resolve(Some(&origin(false, "h")), &[]).unwrap();
        assert_eq!(config.client_hash, DEFAULT_CLIENT_HASH);

        let layers = [Overrides { client_hash: Some("abc".into()), ..default() }];
        assert_eq!(resolve(Some(&origin(false, "h")), &layers).unwrap().client_hash, "abc");
    }

    #[test]
    fn query_parsing_decodes_a_whole_url_in_one_parameter() {
        let overrides = parse_query("?gateway=ws%3A%2F%2F127.0.0.1%3A7667%2Fao");
        assert_eq!(overrides.gateway_url.as_deref(), Some("ws://127.0.0.1:7667/ao"));
    }

    #[test]
    fn query_parsing_reads_every_supported_key_and_ignores_the_rest() {
        let overrides = parse_query(
            "server=http://a&gateway=ws://b/ao&name=N&password=P&hash=H&utm_source=x&novalue",
        );

        assert_eq!(overrides.asset_origin.as_deref(), Some("http://a"));
        assert_eq!(overrides.gateway_url.as_deref(), Some("ws://b/ao"));
        assert_eq!(overrides.character_name.as_deref(), Some("N"));
        assert_eq!(overrides.character_password.as_deref(), Some("P"));
        assert_eq!(overrides.client_hash.as_deref(), Some("H"));
    }

    #[test]
    fn an_empty_query_value_is_not_an_override() {
        // `?name=` in a hand-edited URL means "unset", not "log in as ''".
        let overrides = parse_query("?name=&gateway=");
        assert_eq!(overrides.character_name, None);
        assert_eq!(overrides.gateway_url, None);
    }

    #[test]
    fn query_parsing_survives_a_malformed_escape() {
        // Dropping the bad escape would silently produce a different host.
        let overrides = parse_query("?server=http://a%zz/b&name=a+b");
        assert_eq!(overrides.asset_origin.as_deref(), Some("http://a%zz/b"));
        assert_eq!(overrides.character_name.as_deref(), Some("a b"));
    }

    #[test]
    fn a_percent_before_a_multibyte_character_does_not_panic() {
        // Byte offsets i+1..i+3 land inside the 'é' here. Slicing the &str at
        // those offsets would panic on a non-character boundary, taking the
        // whole client down over a hand-edited URL.
        let overrides = parse_query("?name=%éx");
        assert_eq!(overrides.character_name.as_deref(), Some("%éx"));
    }

    #[test]
    fn an_empty_query_string_yields_no_overrides() {
        assert_eq!(parse_query(""), Overrides::default());
        assert_eq!(parse_query("?"), Overrides::default());
    }
}
