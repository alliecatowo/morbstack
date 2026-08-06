//! A tiny hand-rolled JSON encoder/decoder for *flat* objects only.
//!
//! Morbstack's guest control protocol ("MRB0 framing", see `control.rs`)
//! only ever exchanges single-level JSON objects with string/int/bool
//! values (`{"type":"pong","uptime_ms":1234}`), so a full JSON parser would
//! be a lot of unnecessary machinery — and an external crate is off the
//! table (zero dependencies, offline builds). This module does exactly the
//! subset we need, correctly, with careful string escaping in both
//! directions.
//!
//! Nested objects/arrays are deliberately unsupported: encountering one
//! while parsing is a hard error (`ParseError`), never a panic.

use std::collections::HashMap;
use std::fmt;
use std::iter::Peekable;
use std::str::Chars;

/// A JSON value restricted to what morbinit's control protocol needs.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Str(String),
    Int(i64),
    Bool(bool),
}

/// A parse failure, with a short human-readable reason. Parsing never
/// panics; every malformed input path returns one of these instead.
#[derive(Debug, Clone, PartialEq)]
pub struct ParseError(pub String);

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "jsonlite parse error: {}", self.0)
    }
}

impl std::error::Error for ParseError {}

/// Serialize a flat list of key/value pairs into a compact JSON object
/// string, e.g. `emit(&[("type", Value::Str("pong".into()))])` ->
/// `{"type":"pong"}`.
pub fn emit(fields: &[(&str, Value)]) -> String {
    let mut out = String::from("{");
    for (i, (key, value)) in fields.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('"');
        escape_into(key, &mut out);
        out.push_str("\":");
        match value {
            Value::Str(s) => {
                out.push('"');
                escape_into(s, &mut out);
                out.push('"');
            }
            Value::Int(n) => out.push_str(&n.to_string()),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        }
    }
    out.push('}');
    out
}

/// Append `s` to `out`, escaping the characters JSON requires escaped:
/// `"`, `\`, and control characters (U+0000..=U+001F), using the short
/// escapes (`\n`, `\t`, `\r`) where they exist and `\u00XX` otherwise.
fn escape_into(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
}

/// Parse a flat JSON object into a `String -> Value` map. Whitespace
/// around tokens is tolerated; anything else malformed (missing braces,
/// nested containers, trailing garbage, bad escapes) is a `ParseError`.
pub fn parse(input: &str) -> Result<HashMap<String, Value>, ParseError> {
    let mut chars = input.chars().peekable();
    skip_ws(&mut chars);
    expect_char(&mut chars, '{')?;
    let mut map = HashMap::new();

    skip_ws(&mut chars);
    if peek_is(&mut chars, '}') {
        chars.next();
    } else {
        loop {
            skip_ws(&mut chars);
            let key = parse_string(&mut chars)?;
            skip_ws(&mut chars);
            expect_char(&mut chars, ':')?;
            skip_ws(&mut chars);
            let value = parse_value(&mut chars)?;
            map.insert(key, value);
            skip_ws(&mut chars);
            match chars.next() {
                Some(',') => continue,
                Some('}') => break,
                other => {
                    return Err(ParseError(format!(
                        "expected ',' or '}}' after value, got {:?}",
                        other
                    )))
                }
            }
        }
    }

    skip_ws(&mut chars);
    ensure_end(&mut chars)?;
    Ok(map)
}

fn parse_value(chars: &mut Peekable<Chars>) -> Result<Value, ParseError> {
    match chars.peek() {
        Some('"') => Ok(Value::Str(parse_string(chars)?)),
        Some('{') | Some('[') => Err(ParseError(
            "nested objects/arrays are not supported by jsonlite".to_string(),
        )),
        Some('t') => {
            expect_literal(chars, "true")?;
            Ok(Value::Bool(true))
        }
        Some('f') => {
            expect_literal(chars, "false")?;
            Ok(Value::Bool(false))
        }
        Some(c) if *c == '-' || c.is_ascii_digit() => parse_int(chars),
        other => Err(ParseError(format!("unexpected value start: {:?}", other))),
    }
}

fn parse_string(chars: &mut Peekable<Chars>) -> Result<String, ParseError> {
    match chars.next() {
        Some('"') => {}
        other => return Err(ParseError(format!("expected string, got {:?}", other))),
    }
    let mut s = String::new();
    loop {
        match chars.next() {
            None => return Err(ParseError("unterminated string".to_string())),
            Some('"') => break,
            Some('\\') => match chars.next() {
                Some('"') => s.push('"'),
                Some('\\') => s.push('\\'),
                Some('/') => s.push('/'),
                Some('n') => s.push('\n'),
                Some('t') => s.push('\t'),
                Some('r') => s.push('\r'),
                Some('u') => {
                    let mut hex = String::with_capacity(4);
                    for _ in 0..4 {
                        match chars.next() {
                            Some(c) if c.is_ascii_hexdigit() => hex.push(c),
                            other => {
                                return Err(ParseError(format!(
                                    "bad \\u escape digit: {:?}",
                                    other
                                )))
                            }
                        }
                    }
                    let code = u32::from_str_radix(&hex, 16)
                        .map_err(|_| ParseError(format!("bad \\u escape: {}", hex)))?;
                    match char::from_u32(code) {
                        Some(c) => s.push(c),
                        None => {
                            return Err(ParseError(format!(
                                "\\u{} is not a valid unicode scalar",
                                hex
                            )))
                        }
                    }
                }
                other => return Err(ParseError(format!("unknown escape: {:?}", other))),
            },
            Some(c) => s.push(c),
        }
    }
    Ok(s)
}

fn parse_int(chars: &mut Peekable<Chars>) -> Result<Value, ParseError> {
    let mut s = String::new();
    if let Some('-') = chars.peek() {
        s.push('-');
        chars.next();
    }
    let mut had_digit = false;
    while let Some(c) = chars.peek() {
        if c.is_ascii_digit() {
            s.push(*c);
            chars.next();
            had_digit = true;
        } else {
            break;
        }
    }
    if !had_digit {
        return Err(ParseError("expected digits in number".to_string()));
    }
    s.parse::<i64>()
        .map(Value::Int)
        .map_err(|e| ParseError(format!("integer out of range: {}", e)))
}

fn expect_literal(chars: &mut Peekable<Chars>, lit: &str) -> Result<(), ParseError> {
    for expected in lit.chars() {
        match chars.next() {
            Some(c) if c == expected => {}
            other => {
                return Err(ParseError(format!(
                    "expected literal {:?}, got {:?}",
                    lit, other
                )))
            }
        }
    }
    Ok(())
}

fn skip_ws(chars: &mut Peekable<Chars>) {
    while matches!(chars.peek(), Some(c) if c.is_whitespace()) {
        chars.next();
    }
}

fn expect_char(chars: &mut Peekable<Chars>, expected: char) -> Result<(), ParseError> {
    match chars.next() {
        Some(c) if c == expected => Ok(()),
        other => Err(ParseError(format!(
            "expected {:?}, got {:?}",
            expected, other
        ))),
    }
}

fn peek_is(chars: &mut Peekable<Chars>, c: char) -> bool {
    chars.peek() == Some(&c)
}

fn ensure_end(chars: &mut Peekable<Chars>) -> Result<(), ParseError> {
    match chars.next() {
        None => Ok(()),
        Some(c) => Err(ParseError(format!(
            "unexpected trailing content starting with {:?}",
            c
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emit_produces_exactly_the_json_the_host_decoder_expects() {
        // The anchor for every `emit` caller, including the ~15 reply tests in
        // `control.rs`. Those all decode with `parse`, so `emit` was pinned only
        // against this crate's own reader: verified by switching `emit` to single
        // quotes (with `parse` and `escape_into` relaxed to match) — all 260 guest
        // tests still passed, while the host's Foundation JSONSerialization would have
        // rejected every MRB0 reply the guest sent. Field order is part of the
        // contract's observable output, so this is a whole-string comparison.
        assert_eq!(
            emit(&[
                ("type", Value::Str("pong".to_string())),
                ("uptime_ms", Value::Int(1234)),
                ("ok", Value::Bool(true)),
                ("neg", Value::Int(-7)),
            ]),
            r#"{"type":"pong","uptime_ms":1234,"ok":true,"neg":-7}"#
        );
        assert_eq!(emit(&[]), "{}");
        assert_eq!(
            emit(&[("msg", Value::Str("a\"b\\c\nd".to_string()))]),
            r#"{"msg":"a\"b\\c\nd"}"#
        );
    }

    #[test]
    fn round_trips_simple_object() {
        let encoded = emit(&[
            ("type", Value::Str("pong".to_string())),
            ("uptime_ms", Value::Int(1234)),
            ("ok", Value::Bool(true)),
            ("neg", Value::Int(-7)),
        ]);
        let decoded = parse(&encoded).expect("should parse what we just emitted");
        assert_eq!(decoded.get("type"), Some(&Value::Str("pong".to_string())));
        assert_eq!(decoded.get("uptime_ms"), Some(&Value::Int(1234)));
        assert_eq!(decoded.get("ok"), Some(&Value::Bool(true)));
        assert_eq!(decoded.get("neg"), Some(&Value::Int(-7)));
    }

    #[test]
    fn parses_empty_object() {
        let decoded = parse("{}").unwrap();
        assert!(decoded.is_empty());
        let decoded = parse("  {   }  ").unwrap();
        assert!(decoded.is_empty());
    }

    #[test]
    fn round_trips_all_control_messages_from_the_contract() {
        for encoded in [
            r#"{"type":"ping"}"#,
            r#"{"type":"info"}"#,
            r#"{"type":"clock_sync","unix_nanos":1730000000000000000}"#,
            r#"{"type":"shutdown"}"#,
        ] {
            let decoded = parse(encoded).unwrap();
            assert!(decoded.contains_key("type"));
        }
    }

    #[test]
    fn escapes_quotes_backslashes_and_whitespace_controls() {
        let raw = "quote:\" backslash:\\ nl:\n tab:\t cr:\r";
        let encoded = emit(&[("s", Value::Str(raw.to_string()))]);
        // The literal characters must not appear unescaped in the output.
        assert!(!encoded.contains('\n'));
        assert!(!encoded.contains('\t'));
        assert!(!encoded.contains('\r'));

        let decoded = parse(&encoded).unwrap();
        assert_eq!(decoded.get("s"), Some(&Value::Str(raw.to_string())));
    }

    #[test]
    fn escapes_control_characters_below_0x20_as_u_escapes() {
        let raw = "\u{0001}\u{001f}";
        let encoded = emit(&[("s", Value::Str(raw.to_string()))]);
        assert!(encoded.contains("\\u0001"));
        assert!(encoded.contains("\\u001f"));
        let decoded = parse(&encoded).unwrap();
        assert_eq!(decoded.get("s"), Some(&Value::Str(raw.to_string())));
    }

    #[test]
    fn parses_backslash_u_escape_from_input() {
        let decoded = parse(r#"{"s":"line1\nline2\ttabbed A"}"#).unwrap();
        assert_eq!(
            decoded.get("s"),
            Some(&Value::Str("line1\nline2\ttabbed A".to_string()))
        );
    }

    #[test]
    fn nested_object_is_an_error_not_a_panic() {
        let err = parse(r#"{"a":{"b":1}}"#).unwrap_err();
        assert!(err.0.contains("nested"));
    }

    #[test]
    fn nested_array_is_an_error_not_a_panic() {
        let err = parse(r#"{"a":[1,2,3]}"#).unwrap_err();
        assert!(err.0.contains("nested"));
    }

    #[test]
    fn malformed_missing_colon_is_an_error() {
        assert!(parse(r#"{"a" 1}"#).is_err());
    }

    #[test]
    fn malformed_missing_closing_brace_is_an_error() {
        assert!(parse(r#"{"a":1"#).is_err());
    }

    #[test]
    fn malformed_trailing_garbage_is_an_error() {
        assert!(parse(r#"{"a":1}garbage"#).is_err());
    }

    #[test]
    fn malformed_unterminated_string_is_an_error() {
        assert!(parse(r#"{"a":"unterminated"#).is_err());
    }

    #[test]
    fn not_an_object_is_an_error() {
        assert!(parse("[1,2,3]").is_err());
        assert!(parse("42").is_err());
        assert!(parse("").is_err());
    }
}
