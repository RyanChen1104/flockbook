//! Lightweight syntax highlighting for code blocks. No dependencies, no grammar files: a hand-written scanner
//! that knows keywords, strings, numbers, comments and calls for the common languages. Unknown languages come back
//! as one plain run, so the code still renders.
//!
//! The scanner only classifies. The text of every run is a slice of the input, in order, so joining the runs gives
//! back the input byte for byte (copy and selection stay exact).

/// Class of a code run. `Plain` is drawn in the normal label color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Tone {
    #[default]
    Plain,
    Keyword,
    String,
    Number,
    Comment,
    Function,
}

struct Lang {
    keywords: &'static [&'static str],
    line_comments: &'static [&'static str],
    block_comment: Option<(&'static str, &'static str)>,
    quotes: &'static [char],
    /// `"""` and `'''` strings.
    triple: bool,
    /// Identifiers followed by `(` are calls.
    calls: bool,
}

const PY: &[&str] = &[
    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case",
];
const RUST: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
];
const JS: &[&str] = &[
    "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
];
const GO: &[&str] = &[
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "false", "for", "func", "go", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var",
];
const SWIFT: &[&str] = &[
    "actor", "as", "async", "await", "break", "case", "class", "continue", "default", "defer", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "true", "try", "var", "where", "while",
];
const C: &[&str] = &[
    "auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "false", "float", "for", "if", "include", "int", "long", "namespace", "new", "nullptr", "private", "public", "return", "short", "sizeof", "static", "struct", "switch", "template", "this", "true", "typedef", "union", "unsigned", "using", "void", "while",
];
const SH: &[&str] = &["case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "local", "return", "then", "until", "while", "export"];
const JSON: &[&str] = &["true", "false", "null"];
const SQL: &[&str] = &["select", "from", "where", "insert", "into", "update", "delete", "create", "table", "join", "on", "and", "or", "not", "null", "group", "by", "order", "limit", "as", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "TABLE", "JOIN", "ON", "AND", "OR", "NOT", "NULL", "GROUP", "BY", "ORDER", "LIMIT", "AS"];

fn lang_of(name: &str) -> Option<Lang> {
    let n = name.trim().to_ascii_lowercase();
    let slashes: &[&str] = &["//"];
    let c_block = Some(("/*", "*/"));
    Some(match n.as_str() {
        "python" | "py" | "python3" => Lang { keywords: PY, line_comments: &["#"], block_comment: None, quotes: &['"', '\''], triple: true, calls: true },
        "rust" | "rs" => Lang { keywords: RUST, line_comments: slashes, block_comment: c_block, quotes: &['"'], triple: false, calls: true },
        "javascript" | "js" | "jsx" | "typescript" | "ts" | "tsx" => Lang { keywords: JS, line_comments: slashes, block_comment: c_block, quotes: &['"', '\'', '`'], triple: false, calls: true },
        "go" | "golang" => Lang { keywords: GO, line_comments: slashes, block_comment: c_block, quotes: &['"', '`'], triple: false, calls: true },
        "swift" => Lang { keywords: SWIFT, line_comments: slashes, block_comment: c_block, quotes: &['"'], triple: false, calls: true },
        "c" | "cpp" | "c++" | "h" | "java" | "kotlin" | "cs" | "csharp" => Lang { keywords: C, line_comments: slashes, block_comment: c_block, quotes: &['"', '\''], triple: false, calls: true },
        "bash" | "sh" | "shell" | "zsh" | "console" => Lang { keywords: SH, line_comments: &["#"], block_comment: None, quotes: &['"', '\''], triple: false, calls: false },
        "json" | "jsonc" => Lang { keywords: JSON, line_comments: &[], block_comment: None, quotes: &['"'], triple: false, calls: false },
        "sql" => Lang { keywords: SQL, line_comments: &["--"], block_comment: c_block, quotes: &['\'', '"'], triple: false, calls: true },
        "toml" | "yaml" | "yml" => Lang { keywords: JSON, line_comments: &["#"], block_comment: None, quotes: &['"', '\''], triple: false, calls: false },
        _ => return None,
    })
}

fn is_ident_start(c: char) -> bool {
    c.is_alphabetic() || c == '_'
}
fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Splits `code` into contiguous runs. Unknown `lang` (or none) gives one `Plain` run.
pub fn tokenize<'a>(lang: Option<&str>, code: &'a str) -> Vec<(Tone, &'a str)> {
    let Some(l) = lang.and_then(lang_of) else {
        return if code.is_empty() { vec![] } else { vec![(Tone::Plain, code)] };
    };
    let mut out: Vec<(Tone, &str)> = Vec::new();
    let mut plain_from = 0usize;
    let mut i = 0usize;
    let bytes = code.as_bytes();
    let mut prev_ident_or_dot_digit = false;

    macro_rules! emit {
        ($tone:expr, $start:expr, $end:expr) => {{
            if plain_from < $start {
                out.push((Tone::Plain, &code[plain_from..$start]));
            }
            out.push(($tone, &code[$start..$end]));
            plain_from = $end;
            i = $end;
        }};
    }

    while i < code.len() {
        let rest = &code[i..];
        let c = rest.chars().next().unwrap();
        // Comments.
        if l.line_comments.iter().any(|p| rest.starts_with(*p)) {
            let end = rest.find('\n').map(|n| i + n).unwrap_or(code.len());
            emit!(Tone::Comment, i, end);
            prev_ident_or_dot_digit = false;
            continue;
        }
        if let Some((open, close)) = l.block_comment {
            if rest.starts_with(open) {
                let end = rest[open.len()..].find(close).map(|n| i + open.len() + n + close.len()).unwrap_or(code.len());
                emit!(Tone::Comment, i, end);
                prev_ident_or_dot_digit = false;
                continue;
            }
        }
        // Strings.
        if l.quotes.contains(&c) {
            let mut end;
            if l.triple && (rest.starts_with("\"\"\"") || rest.starts_with("'''")) {
                let q = &rest[..3];
                end = rest[3..].find(q).map(|n| i + 3 + n + 3).unwrap_or(code.len());
            } else {
                let body = i + c.len_utf8();
                end = body;
                let mut esc = false;
                for (off, ch) in code[body..].char_indices() {
                    let here = body + off;
                    if esc {
                        esc = false;
                    } else if ch == '\\' {
                        esc = true;
                    } else if ch == c {
                        end = here + ch.len_utf8();
                        break;
                    } else if ch == '\n' && c != '`' {
                        end = here;
                        break;
                    }
                    end = here + ch.len_utf8();
                }
            }
            emit!(Tone::String, i, end);
            prev_ident_or_dot_digit = false;
            continue;
        }
        // Numbers (not glued to an identifier).
        if c.is_ascii_digit() && !prev_ident_or_dot_digit {
            let mut end = i;
            while end < code.len() {
                let b = bytes[end] as char;
                let next_digit = bytes.get(end + 1).is_some_and(|n| n.is_ascii_digit());
                if b.is_ascii_alphanumeric() || b == '_' || (b == '.' && next_digit) {
                    end += 1;
                } else {
                    break;
                }
            }
            emit!(Tone::Number, i, end);
            prev_ident_or_dot_digit = true;
            continue;
        }
        // Identifiers.
        if is_ident_start(c) {
            let end = rest.char_indices().find(|(_, ch)| !is_ident(*ch)).map(|(n, _)| i + n).unwrap_or(code.len());
            let word = &code[i..end];
            let prev_def_in_out = matches!(out.last(), Some((Tone::Keyword, k)) if matches!(*k, "def" | "fn" | "func" | "function" | "class" | "struct" | "enum" | "trait")) && code[plain_from..i].chars().all(|ch| ch == ' ' || ch == '\t');
            if l.keywords.contains(&word) {
                emit!(Tone::Keyword, i, end);
            } else if prev_def_in_out || (l.calls && code[end..].starts_with('(')) {
                emit!(Tone::Function, i, end);
            } else {
                i = end;
            }
            prev_ident_or_dot_digit = true;
            continue;
        }
        prev_ident_or_dot_digit = false;
        i += c.len_utf8();
    }
    if plain_from < code.len() {
        out.push((Tone::Plain, &code[plain_from..]));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tones<'a>(lang: &str, code: &'a str) -> Vec<(Tone, &'a str)> {
        tokenize(Some(lang), code).into_iter().filter(|(t, _)| *t != Tone::Plain).collect()
    }

    #[test]
    fn python_def_strings_numbers_comments() {
        let code = "def score(x):\n    # note\n    return x * 0.5 + len(\"a#b\")  # tail\n";
        let t = tones("python", code);
        assert!(t.contains(&(Tone::Keyword, "def")));
        assert!(t.contains(&(Tone::Function, "score")));
        assert!(t.contains(&(Tone::Comment, "# note")));
        assert!(t.contains(&(Tone::Keyword, "return")));
        assert!(t.contains(&(Tone::Number, "0.5")));
        assert!(t.contains(&(Tone::Function, "len")));
        assert!(t.contains(&(Tone::String, "\"a#b\"")));
        assert!(t.contains(&(Tone::Comment, "# tail")));
    }

    #[test]
    fn runs_join_back_to_the_input() {
        for (lang, code) in [("python", "x = '''a\nb''' + 1\nclass A: pass\u{4e2d}"), ("rust", "fn main() { /* c */ let s = \"\\\"\"; }"), ("json", "{\"a\": [1, 2.5, null]}"), ("bash", "echo 'a' # c\nif x; then y; fi")] {
            let joined: String = tokenize(Some(lang), code).iter().map(|(_, s)| *s).collect();
            assert_eq!(joined, code, "{lang}");
        }
    }

    #[test]
    fn unknown_language_is_one_plain_run() {
        assert_eq!(tokenize(Some("brainfuck"), "+++"), vec![(Tone::Plain, "+++")]);
        assert_eq!(tokenize(None, "x"), vec![(Tone::Plain, "x")]);
        assert!(tokenize(Some("python"), "").is_empty());
    }

    #[test]
    fn digits_inside_identifiers_are_not_numbers() {
        let t = tones("python", "log1p(x2) + 30");
        assert!(!t.iter().any(|(k, s)| *k == Tone::Number && (*s == "1" || *s == "2")));
        assert!(t.contains(&(Tone::Number, "30")));
    }

    #[test]
    fn rust_comment_and_fn_name() {
        let t = tones("rust", "// hi\nfn run() {}");
        assert!(t.contains(&(Tone::Comment, "// hi")));
        assert!(t.contains(&(Tone::Function, "run")));
    }
}
