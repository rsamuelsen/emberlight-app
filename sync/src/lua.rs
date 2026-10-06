//! Strict reader for WoW SavedVariables files.
//!
//! Accepts only `Name = <literal>` statements, where a literal is nil, a boolean, a number, a
//! quoted string or a table of literals. Anything else (calls, operators, references to other
//! variables, long-bracket strings) is a parse error. Nothing is ever evaluated.

use std::collections::BTreeMap;
use std::fmt;

pub const MAX_INPUT: usize = 32 * 1024 * 1024;
pub const MAX_DEPTH: usize = 64;
pub const MAX_STRING: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Nil,
    Bool(bool),
    Number(f64),
    Str(Vec<u8>),
    Table(Table),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Key {
    Int(i64),
    Str(Vec<u8>),
}

pub type Table = BTreeMap<Key, Value>;

impl Value {
    pub fn as_table(&self) -> Option<&Table> {
        match self {
            Value::Table(t) => Some(t),
            _ => None,
        }
    }

    pub fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    /// An integral number that fits in i64.
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Number(n) if n.is_finite() && n.fract() == 0.0 && n.abs() < 9.0e15 => Some(*n as i64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }
}

pub fn field<'a>(table: &'a Table, name: &str) -> Option<&'a Value> {
    table.get(&Key::Str(name.as_bytes().to_vec()))
}

#[derive(Debug, Clone, PartialEq)]
pub struct ParseError {
    pub line: usize,
    pub message: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

impl std::error::Error for ParseError {}

/// Parse a SavedVariables file into its global assignments.
pub fn parse(input: &[u8]) -> Result<BTreeMap<String, Value>, ParseError> {
    if input.len() > MAX_INPUT {
        return Err(ParseError { line: 0, message: "file is too large".into() });
    }
    let input = input.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(input);
    let mut p = Parser { s: input, pos: 0, line: 1, depth: 0 };
    let mut globals = BTreeMap::new();
    loop {
        p.skip_space()?;
        if p.pos >= p.s.len() {
            return Ok(globals);
        }
        let name = p.name().ok_or_else(|| p.err("expected a variable name"))?;
        if is_keyword(&name) {
            return Err(p.err(&format!("unexpected keyword '{name}'")));
        }
        p.skip_space()?;
        p.expect(b'=')?;
        p.skip_space()?;
        let value = p.value()?;
        p.skip_space()?;
        if p.peek() == Some(b';') {
            p.pos += 1;
        }
        match value {
            Value::Nil => {
                globals.remove(&name);
            }
            v => {
                globals.insert(name, v);
            }
        }
    }
}

fn is_keyword(word: &str) -> bool {
    matches!(
        word,
        "and" | "break" | "do" | "else" | "elseif" | "end" | "false" | "for" | "function" | "if" | "in"
            | "local" | "nil" | "not" | "or" | "repeat" | "return" | "then" | "true" | "until" | "while"
    )
}

struct Parser<'a> {
    s: &'a [u8],
    pos: usize,
    line: usize,
    depth: usize,
}

impl Parser<'_> {
    fn err(&self, message: &str) -> ParseError {
        ParseError { line: self.line, message: message.into() }
    }

    fn peek(&self) -> Option<u8> {
        self.s.get(self.pos).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<u8> {
        self.s.get(self.pos + offset).copied()
    }

    fn expect(&mut self, b: u8) -> Result<(), ParseError> {
        if self.peek() == Some(b) {
            self.pos += 1;
            Ok(())
        } else {
            Err(self.err(&format!("expected '{}'", b as char)))
        }
    }

    fn skip_space(&mut self) -> Result<(), ParseError> {
        while let Some(b) = self.peek() {
            match b {
                b'\n' => {
                    self.line += 1;
                    self.pos += 1;
                }
                b' ' | b'\t' | b'\r' | 0x0b | 0x0c => self.pos += 1,
                b'-' if self.peek_at(1) == Some(b'-') => {
                    self.pos += 2;
                    if let Some(level) = self.long_bracket_level() {
                        self.skip_long_comment(level)?;
                    } else {
                        while let Some(c) = self.peek() {
                            if c == b'\n' {
                                break;
                            }
                            self.pos += 1;
                        }
                    }
                }
                _ => break,
            }
        }
        Ok(())
    }

    /// If positioned at `[`, `[=`... `[`, return the level without consuming.
    fn long_bracket_level(&self) -> Option<usize> {
        if self.peek() != Some(b'[') {
            return None;
        }
        let mut level = 0;
        while self.peek_at(1 + level) == Some(b'=') {
            level += 1;
        }
        (self.peek_at(1 + level) == Some(b'[')).then_some(level)
    }

    fn skip_long_comment(&mut self, level: usize) -> Result<(), ParseError> {
        self.pos += level + 2;
        while self.pos < self.s.len() {
            let b = self.s[self.pos];
            if b == b'\n' {
                self.line += 1;
            }
            if b == b']'
                && (1..=level).all(|i| self.peek_at(i) == Some(b'='))
                && self.peek_at(level + 1) == Some(b']')
            {
                self.pos += level + 2;
                return Ok(());
            }
            self.pos += 1;
        }
        Err(self.err("unfinished long comment"))
    }

    fn name(&mut self) -> Option<String> {
        let start = self.pos;
        match self.peek() {
            Some(b) if b.is_ascii_alphabetic() || b == b'_' => self.pos += 1,
            _ => return None,
        }
        while let Some(b) = self.peek() {
            if b.is_ascii_alphanumeric() || b == b'_' {
                self.pos += 1;
            } else {
                break;
            }
        }
        Some(String::from_utf8(self.s[start..self.pos].to_vec()).expect("ASCII identifier"))
    }

    fn value(&mut self) -> Result<Value, ParseError> {
        match self.peek() {
            Some(b'{') => self.table(),
            Some(b'"') | Some(b'\'') => self.string().map(Value::Str),
            Some(b'[') if self.long_bracket_level().is_some() => Err(self.err("long-bracket strings are not supported")),
            Some(b) if b.is_ascii_digit() || b == b'.' || b == b'-' => self.number(),
            Some(b) if b.is_ascii_alphabetic() || b == b'_' => {
                let word = self.name().expect("checked first byte");
                match word.as_str() {
                    "true" => Ok(Value::Bool(true)),
                    "false" => Ok(Value::Bool(false)),
                    "nil" => Ok(Value::Nil),
                    _ => Err(self.err(&format!("'{word}' is not a literal value"))),
                }
            }
            Some(_) => Err(self.err("expected a value")),
            None => Err(self.err("unexpected end of file")),
        }
    }

    fn number(&mut self) -> Result<Value, ParseError> {
        let negative = self.peek() == Some(b'-');
        if negative {
            self.pos += 1;
        }
        let start = self.pos;
        let n = if self.peek() == Some(b'0') && matches!(self.peek_at(1), Some(b'x') | Some(b'X')) {
            self.pos += 2;
            let digits = self.pos;
            while self.peek().is_some_and(|b| b.is_ascii_hexdigit()) {
                self.pos += 1;
            }
            let hex = std::str::from_utf8(&self.s[digits..self.pos]).expect("hex digits");
            u64::from_str_radix(hex, 16).map_err(|_| self.err("invalid hexadecimal number"))? as f64
        } else {
            while self.peek().is_some_and(|b| b.is_ascii_digit() || b == b'.') {
                self.pos += 1;
            }
            if matches!(self.peek(), Some(b'e') | Some(b'E')) {
                self.pos += 1;
                if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                    self.pos += 1;
                }
                while self.peek().is_some_and(|b| b.is_ascii_digit()) {
                    self.pos += 1;
                }
            }
            let text = std::str::from_utf8(&self.s[start..self.pos]).expect("number characters");
            if text.is_empty() || !text.bytes().any(|b| b.is_ascii_digit()) {
                return Err(self.err("invalid number"));
            }
            text.parse::<f64>().map_err(|_| self.err("invalid number"))?
        };
        if self.peek().is_some_and(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return Err(self.err("invalid number"));
        }
        if !n.is_finite() {
            return Err(self.err("number is out of range"));
        }
        Ok(Value::Number(if negative { -n } else { n }))
    }

    fn string(&mut self) -> Result<Vec<u8>, ParseError> {
        let quote = self.s[self.pos];
        self.pos += 1;
        let mut out = Vec::new();
        loop {
            if out.len() > MAX_STRING {
                return Err(self.err("string is too long"));
            }
            let b = self.peek().ok_or_else(|| self.err("unfinished string"))?;
            self.pos += 1;
            match b {
                _ if b == quote => return Ok(out),
                b'\n' | b'\r' => return Err(self.err("unfinished string")),
                b'\\' => {
                    let e = self.peek().ok_or_else(|| self.err("unfinished string"))?;
                    self.pos += 1;
                    match e {
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'a' => out.push(0x07),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'v' => out.push(0x0b),
                        b'\\' | b'"' | b'\'' => out.push(e),
                        b'\n' => {
                            self.line += 1;
                            out.push(b'\n');
                        }
                        b'\r' => {
                            if self.peek() == Some(b'\n') {
                                self.pos += 1;
                            }
                            self.line += 1;
                            out.push(b'\n');
                        }
                        b'0'..=b'9' => {
                            let mut code = (e - b'0') as u32;
                            for _ in 0..2 {
                                match self.peek() {
                                    Some(d) if d.is_ascii_digit() => {
                                        code = code * 10 + (d - b'0') as u32;
                                        self.pos += 1;
                                    }
                                    _ => break,
                                }
                            }
                            if code > 255 {
                                return Err(self.err("escape sequence is too large"));
                            }
                            out.push(code as u8);
                        }
                        _ => return Err(self.err("invalid escape sequence")),
                    }
                }
                _ => out.push(b),
            }
        }
    }

    fn table(&mut self) -> Result<Value, ParseError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("tables are nested too deeply"));
        }
        self.pos += 1;
        let mut table = Table::new();
        let mut next_index: i64 = 1;
        loop {
            self.skip_space()?;
            if self.peek() == Some(b'}') {
                self.pos += 1;
                break;
            }
            let (key, value) = if self.peek() == Some(b'[') && self.long_bracket_level().is_none() {
                self.pos += 1;
                self.skip_space()?;
                let key = match self.value()? {
                    Value::Str(s) => Key::Str(s),
                    v @ Value::Number(_) => Key::Int(v.as_int().ok_or_else(|| self.err("table keys must be whole numbers or strings"))?),
                    _ => return Err(self.err("table keys must be whole numbers or strings")),
                };
                self.skip_space()?;
                self.expect(b']')?;
                self.skip_space()?;
                self.expect(b'=')?;
                self.skip_space()?;
                (key, self.value()?)
            } else if self.peek().is_some_and(|b| b.is_ascii_alphabetic() || b == b'_') {
                let save = (self.pos, self.line);
                let word = self.name().expect("checked first byte");
                self.skip_space()?;
                if self.peek() == Some(b'=') && self.peek_at(1) != Some(b'=') && !is_keyword(&word) {
                    self.pos += 1;
                    self.skip_space()?;
                    (Key::Str(word.into_bytes()), self.value()?)
                } else {
                    (self.pos, self.line) = save;
                    let key = Key::Int(next_index);
                    next_index += 1;
                    (key, self.value()?)
                }
            } else {
                let key = Key::Int(next_index);
                next_index += 1;
                (key, self.value()?)
            };
            if value != Value::Nil {
                table.insert(key, value);
            } else {
                table.remove(&key);
            }
            self.skip_space()?;
            match self.peek() {
                Some(b',') | Some(b';') => self.pos += 1,
                Some(b'}') => {}
                _ => return Err(self.err("expected ',' or '}' in table")),
            }
        }
        self.depth -= 1;
        Ok(Value::Table(table))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one(src: &str) -> Value {
        parse(src.as_bytes()).unwrap().remove("X").unwrap()
    }

    fn fails(src: &str) -> String {
        parse(src.as_bytes()).unwrap_err().message
    }

    #[test]
    fn wow_layout() {
        let v = one("\nX = {\n\t[\"a\"] = {\n\t\t\"one\", -- [1]\n\t\t\"two\", -- [2]\n\t},\n\t[5] = true,\n}\n");
        let t = v.as_table().unwrap();
        let a = field(t, "a").unwrap().as_table().unwrap();
        assert_eq!(a.get(&Key::Int(2)).unwrap().as_bytes().unwrap(), b"two");
        assert_eq!(t.get(&Key::Int(5)), Some(&Value::Bool(true)));
    }

    #[test]
    fn plain_lua_table_forms() {
        let v = one("X = { a = 1; b = 'x', 'pos', [ \"c\" ] = -2.5e1, --[[ c ]] --[==[ ]] ]==] }");
        let t = v.as_table().unwrap();
        assert_eq!(field(t, "a").unwrap().as_int(), Some(1));
        assert_eq!(t.get(&Key::Int(1)).unwrap().as_bytes().unwrap(), b"pos");
        assert_eq!(field(t, "c"), Some(&Value::Number(-25.0)));
    }

    #[test]
    fn escapes() {
        let v = one(r#"X = "q\"b\\n\nt\tz\0009\255'\'""#);
        assert_eq!(v.as_bytes().unwrap(), b"q\"b\\n\nt\tz\x009\xff''");
    }

    #[test]
    fn numbers() {
        assert_eq!(one("X = 1800000000001").as_int(), Some(1800000000001));
        assert_eq!(one("X = 1.8e+12").as_int(), Some(1800000000000));
        assert_eq!(one("X = 0x1F").as_int(), Some(31));
        assert_eq!(one("X = .5"), Value::Number(0.5));
        assert_eq!(one("X = 0.5").as_int(), None);
    }

    #[test]
    fn nil_removes() {
        let g = parse(b"X = 1\nX = nil\nY = { a = nil, 1, nil, 3 }").unwrap();
        assert!(!g.contains_key("X"));
        let t = g["Y"].as_table().unwrap();
        assert!(field(t, "a").is_none());
        assert_eq!(t.get(&Key::Int(3)).unwrap().as_int(), Some(3));
        assert!(t.get(&Key::Int(2)).is_none());
    }

    #[test]
    fn bom_and_semicolons() {
        assert_eq!(parse(b"\xEF\xBB\xBFX = 1; Y = 2").unwrap().len(), 2);
    }

    #[test]
    fn rejects_code() {
        assert!(fails("X = os.execute('x')").contains("not a literal"));
        assert!(fails("X = 1 + 2").contains("expected a variable name"));
        assert!(fails("X = { f() }").contains("not a literal"));
        assert!(fails("X = function() end").contains("not a literal"));
        assert!(fails("X = Y").contains("not a literal"));
        assert!(fails("X = [[long]]").contains("long-bracket"));
        assert!(fails("X = { [[a]] }").contains("long-bracket"));
        assert!(fails("local X = 1").contains("keyword"));
        assert!(fails("X = \"unfinished").contains("unfinished"));
        assert!(fails("X = \"a\nb\"").contains("unfinished"));
        assert!(fails("X = \"\\q\"").contains("invalid escape"));
        assert!(fails("X = \"\\300\"").contains("too large"));
        assert!(fails("X = { [true] = 1 }").contains("keys"));
        assert!(fails("X = { [1.5] = 1 }").contains("keys"));
        assert!(fails("X = { 1 2 }").contains("expected ','"));
        assert!(fails("X = 1e999").contains("out of range"));
        assert!(fails("X = 12abc").contains("invalid number"));
        assert!(fails("X = -").contains("invalid number"));
        assert!(fails("X = { a == 1 }").contains("not a literal"));
    }

    #[test]
    fn depth_limit() {
        let deep = format!("X = {}{}", "{".repeat(MAX_DEPTH + 1), "}".repeat(MAX_DEPTH + 1));
        assert!(fails(&deep).contains("nested"));
        let ok = format!("X = {}{}", "{".repeat(MAX_DEPTH), "}".repeat(MAX_DEPTH));
        assert!(parse(ok.as_bytes()).is_ok());
    }
}
