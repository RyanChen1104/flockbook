//! Keys to xterm bytes. Pure functions: no I/O, no focus, no policy. The caller decides when a key may be sent.
//!
//! Not handled here, on purpose: Cmd combinations (the app owns them; Cmd+V is the paste path) and Ctrl+` (the
//! "Show terminal" shortcut). They return `None`, so the key stays free for the app.

use iced::keyboard::key::Named;
use iced::keyboard::{Key, Modifiers};

/// xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). `None` when no modifier is down.
fn modifier_param(mods: Modifiers) -> Option<u8> {
    let m = (mods.shift() as u8) | ((mods.alt() as u8) << 1) | ((mods.control() as u8) << 2);
    (m != 0).then_some(1 + m)
}

/// `ESC [ <final>` or `ESC O <final>` (application mode), or `ESC [ 1 ; <m> <final>` with modifiers.
fn csi_or_ss3(final_byte: u8, mods: Modifiers, app: bool) -> Vec<u8> {
    match modifier_param(mods) {
        Some(m) => format!("\x1b[1;{m}{}", final_byte as char).into_bytes(),
        None if app => vec![0x1b, b'O', final_byte],
        None => vec![0x1b, b'[', final_byte],
    }
}

/// `ESC [ <n> ~`, or `ESC [ <n> ; <m> ~` with modifiers.
fn tilde(n: u8, mods: Modifiers) -> Vec<u8> {
    match modifier_param(mods) {
        Some(m) => format!("\x1b[{n};{m}~").into_bytes(),
        None => format!("\x1b[{n}~").into_bytes(),
    }
}

/// F1-F4: `ESC O P..S`, with modifiers `ESC [ 1 ; m P..S`.
fn f_low(final_byte: u8, mods: Modifiers) -> Vec<u8> {
    csi_or_ss3(final_byte, mods, true)
}

fn named_bytes(n: Named, mods: Modifiers, app_cursor: bool) -> Option<Vec<u8>> {
    Some(match n {
        Named::Enter => {
            if mods.alt() {
                vec![0x1b, b'\r']
            } else {
                vec![b'\r']
            }
        }
        Named::Backspace => {
            if mods.alt() {
                vec![0x1b, 0x7f]
            } else {
                vec![0x7f]
            }
        }
        Named::Tab => {
            if mods.shift() {
                b"\x1b[Z".to_vec()
            } else {
                vec![b'\t']
            }
        }
        Named::Escape => {
            if mods.alt() {
                vec![0x1b, 0x1b]
            } else {
                vec![0x1b]
            }
        }
        Named::Space => {
            if mods.control() {
                vec![0]
            } else if mods.alt() {
                vec![0x1b, b' ']
            } else {
                vec![b' ']
            }
        }
        Named::ArrowUp => csi_or_ss3(b'A', mods, app_cursor),
        Named::ArrowDown => csi_or_ss3(b'B', mods, app_cursor),
        Named::ArrowRight => csi_or_ss3(b'C', mods, app_cursor),
        Named::ArrowLeft => csi_or_ss3(b'D', mods, app_cursor),
        Named::Home => csi_or_ss3(b'H', mods, app_cursor),
        Named::End => csi_or_ss3(b'F', mods, app_cursor),
        Named::PageUp => tilde(5, mods),
        Named::PageDown => tilde(6, mods),
        Named::Insert => tilde(2, mods),
        Named::Delete => tilde(3, mods),
        Named::F1 => f_low(b'P', mods),
        Named::F2 => f_low(b'Q', mods),
        Named::F3 => f_low(b'R', mods),
        Named::F4 => f_low(b'S', mods),
        Named::F5 => tilde(15, mods),
        Named::F6 => tilde(17, mods),
        Named::F7 => tilde(18, mods),
        Named::F8 => tilde(19, mods),
        Named::F9 => tilde(20, mods),
        Named::F10 => tilde(21, mods),
        Named::F11 => tilde(23, mods),
        Named::F12 => tilde(24, mods),
        _ => return None,
    })
}

/// The control byte for Ctrl + `c` (xterm rules), if there is one.
fn control_byte(c: char) -> Option<u8> {
    match c {
        'a'..='z' => Some(c as u8 - b'a' + 1),
        'A'..='Z' => Some(c as u8 - b'A' + 1),
        '@' | '2' | ' ' => Some(0),
        '[' | '3' => Some(0x1b),
        '\\' | '4' => Some(0x1c),
        ']' | '5' => Some(0x1d),
        '^' | '6' => Some(0x1e),
        '_' | '-' | '/' | '7' => Some(0x1f),
        '8' | '?' => Some(0x7f),
        _ => None,
    }
}

/// The US-layout Shift of a digit or symbol key. Alt sends the logical key, which has no Shift applied, so the
/// shifted character is rebuilt here (Option+Shift+1 would otherwise send `ESC 1`).
fn shifted_symbol(c: char) -> char {
    match c {
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        '`' => '~',
        other => other,
    }
}

/// Encodes one key press for the program in the terminal. `None` = not a terminal key (or reserved for the app).
///
/// - `key`: the logical key without modifiers (what iced calls `key`).
/// - `text`: the text the press produced (`KeyPressed::text`), which carries Shift and the layout.
/// - `app_cursor`: the program set application cursor keys (DECCKM).
///
/// Alt sends the key with an ESC prefix (Shift applied, US layout for digits and symbols). Ctrl+letter sends the control byte.
pub fn encode_key(key: &Key, mods: Modifiers, text: Option<&str>, app_cursor: bool) -> Option<Vec<u8>> {
    if mods.logo() {
        return None;
    }
    match key.as_ref() {
        Key::Named(n) => named_bytes(n, mods, app_cursor),
        Key::Character(c) => {
            let ch = c.chars().next()?;
            if mods.control() {
                if ch == '`' {
                    return None;
                }
                // Ctrl+digit without a control byte (0, 1, 9) sends the digit itself, like xterm.
                let b = match control_byte(ch) {
                    Some(b) => b,
                    None if ch.is_ascii_digit() => ch as u8,
                    None => return None,
                };
                return Some(if mods.alt() { vec![0x1b, b] } else { vec![b] });
            }
            if mods.alt() {
                // The logical key is without Option's special characters; Shift still upper-cases it.
                let shown: String = if mods.shift() { c.chars().map(shifted_symbol).collect::<String>().to_uppercase() } else { c.to_string() };
                let mut v = vec![0x1b];
                v.extend_from_slice(shown.as_bytes());
                return Some(v);
            }
            let t = text.filter(|t| !t.is_empty() && !t.chars().any(char::is_control)).unwrap_or(c);
            Some(t.as_bytes().to_vec())
        }
        Key::Unidentified => None,
    }
}

/// Text from an input method commit. Newlines stay as typed; it goes to the program as UTF-8.
pub fn commit_bytes(text: &str) -> Vec<u8> {
    text.as_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ch(s: &str) -> Key {
        Key::Character(s.into())
    }
    fn named(n: Named) -> Key {
        Key::Named(n)
    }
    fn enc(k: Key, m: Modifiers) -> Option<Vec<u8>> {
        encode_key(&k, m, None, false)
    }
    const NONE: Modifiers = Modifiers::empty();

    #[test]
    fn printable_text_uses_the_produced_text() {
        assert_eq!(encode_key(&ch("a"), NONE, Some("a"), false), Some(b"a".to_vec()));
        assert_eq!(encode_key(&ch("a"), Modifiers::SHIFT, Some("A"), false), Some(b"A".to_vec()));
        assert_eq!(encode_key(&ch("e"), NONE, Some("\u{00e9}"), false), Some("\u{00e9}".as_bytes().to_vec()));
        assert_eq!(enc(ch("x"), NONE), Some(b"x".to_vec()), "no text: the key itself");
        assert_eq!(encode_key(&named(Named::Space), NONE, Some(" "), false), Some(b" ".to_vec()));
    }

    #[test]
    fn enter_backspace_tab_escape() {
        assert_eq!(enc(named(Named::Enter), NONE), Some(b"\r".to_vec()));
        assert_eq!(enc(named(Named::Backspace), NONE), Some(vec![0x7f]));
        assert_eq!(enc(named(Named::Tab), NONE), Some(b"\t".to_vec()));
        assert_eq!(enc(named(Named::Tab), Modifiers::SHIFT), Some(b"\x1b[Z".to_vec()));
        assert_eq!(enc(named(Named::Escape), NONE), Some(vec![0x1b]));
    }

    #[test]
    fn arrows_normal_and_application_mode() {
        assert_eq!(enc(named(Named::ArrowUp), NONE), Some(b"\x1b[A".to_vec()));
        assert_eq!(enc(named(Named::ArrowLeft), NONE), Some(b"\x1b[D".to_vec()));
        assert_eq!(encode_key(&named(Named::ArrowUp), NONE, None, true), Some(b"\x1bOA".to_vec()));
        assert_eq!(encode_key(&named(Named::ArrowRight), NONE, None, true), Some(b"\x1bOC".to_vec()));
    }

    #[test]
    fn modified_arrows_use_the_csi_form_even_in_application_mode() {
        assert_eq!(encode_key(&named(Named::ArrowRight), Modifiers::CTRL, None, true), Some(b"\x1b[1;5C".to_vec()));
        assert_eq!(enc(named(Named::ArrowLeft), Modifiers::ALT), Some(b"\x1b[1;3D".to_vec()));
        assert_eq!(enc(named(Named::ArrowUp), Modifiers::SHIFT), Some(b"\x1b[1;2A".to_vec()));
    }

    #[test]
    fn home_end_page_delete_insert() {
        assert_eq!(enc(named(Named::Home), NONE), Some(b"\x1b[H".to_vec()));
        assert_eq!(enc(named(Named::End), NONE), Some(b"\x1b[F".to_vec()));
        assert_eq!(encode_key(&named(Named::Home), NONE, None, true), Some(b"\x1bOH".to_vec()));
        assert_eq!(enc(named(Named::PageUp), NONE), Some(b"\x1b[5~".to_vec()));
        assert_eq!(enc(named(Named::PageDown), NONE), Some(b"\x1b[6~".to_vec()));
        assert_eq!(enc(named(Named::Delete), NONE), Some(b"\x1b[3~".to_vec()));
        assert_eq!(enc(named(Named::Insert), NONE), Some(b"\x1b[2~".to_vec()));
        assert_eq!(enc(named(Named::Delete), Modifiers::CTRL), Some(b"\x1b[3;5~".to_vec()));
    }

    #[test]
    fn function_keys() {
        let want: [(&str, Named); 12] = [
            ("\x1bOP", Named::F1),
            ("\x1bOQ", Named::F2),
            ("\x1bOR", Named::F3),
            ("\x1bOS", Named::F4),
            ("\x1b[15~", Named::F5),
            ("\x1b[17~", Named::F6),
            ("\x1b[18~", Named::F7),
            ("\x1b[19~", Named::F8),
            ("\x1b[20~", Named::F9),
            ("\x1b[21~", Named::F10),
            ("\x1b[23~", Named::F11),
            ("\x1b[24~", Named::F12),
        ];
        for (bytes, n) in want {
            assert_eq!(enc(named(n), NONE), Some(bytes.as_bytes().to_vec()), "{n:?}");
        }
        assert_eq!(enc(named(Named::F1), Modifiers::SHIFT), Some(b"\x1b[1;2P".to_vec()));
        assert_eq!(enc(named(Named::F5), Modifiers::CTRL), Some(b"\x1b[15;5~".to_vec()));
    }

    #[test]
    fn ctrl_letters_and_punctuation() {
        assert_eq!(enc(ch("a"), Modifiers::CTRL), Some(vec![1]));
        assert_eq!(enc(ch("c"), Modifiers::CTRL), Some(vec![3]));
        assert_eq!(enc(ch("z"), Modifiers::CTRL), Some(vec![26]));
        assert_eq!(enc(ch("C"), Modifiers::CTRL | Modifiers::SHIFT), Some(vec![3]));
        assert_eq!(enc(ch("["), Modifiers::CTRL), Some(vec![0x1b]));
        assert_eq!(enc(ch("\\"), Modifiers::CTRL), Some(vec![0x1c]));
        assert_eq!(enc(named(Named::Space), Modifiers::CTRL), Some(vec![0]));
    }

    #[test]
    fn alt_is_an_escape_prefix() {
        assert_eq!(encode_key(&ch("b"), Modifiers::ALT, Some("\u{222b}"), false), Some(b"\x1bb".to_vec()), "not the Option character");
        assert_eq!(enc(ch("f"), Modifiers::ALT | Modifiers::SHIFT), Some(b"\x1bF".to_vec()));
        assert_eq!(enc(ch("d"), Modifiers::ALT | Modifiers::CTRL), Some(vec![0x1b, 4]));
        assert_eq!(enc(named(Named::Backspace), Modifiers::ALT), Some(vec![0x1b, 0x7f]));
    }

    #[test]
    fn cmd_and_ctrl_backtick_are_left_to_the_app() {
        assert_eq!(enc(ch("c"), Modifiers::LOGO), None);
        assert_eq!(enc(ch("v"), Modifiers::LOGO), None);
        assert_eq!(enc(named(Named::ArrowLeft), Modifiers::LOGO), None);
        assert_eq!(enc(ch("`"), Modifiers::CTRL), None);
    }

    #[test]
    fn unknown_keys_send_nothing() {
        assert_eq!(enc(Key::Unidentified, NONE), None);
        assert_eq!(enc(named(Named::Shift), Modifiers::SHIFT), None);
        assert_eq!(enc(named(Named::CapsLock), NONE), None);
    }

    #[test]
    fn ime_commit_is_utf8() {
        assert_eq!(commit_bytes("你好"), "你好".as_bytes().to_vec());
    }

    #[test]
    fn alt_enter_and_alt_escape_are_escape_prefixed() {
        assert_eq!(enc(named(Named::Enter), Modifiers::ALT), Some(b"\x1b\r".to_vec()));
        assert_eq!(enc(named(Named::Escape), Modifiers::ALT), Some(b"\x1b\x1b".to_vec()));
        assert_eq!(enc(named(Named::Enter), NONE), Some(b"\r".to_vec()));
    }

    #[test]
    fn alt_shift_digits_and_symbols_send_the_shifted_char() {
        let alt_shift = Modifiers::ALT | Modifiers::SHIFT;
        assert_eq!(enc(ch("1"), alt_shift), Some(b"\x1b!".to_vec()));
        assert_eq!(enc(ch("2"), alt_shift), Some(b"\x1b@".to_vec()));
        assert_eq!(enc(ch("9"), alt_shift), Some(b"\x1b(".to_vec()));
        assert_eq!(enc(ch("/"), alt_shift), Some(b"\x1b?".to_vec()));
        assert_eq!(enc(ch("-"), alt_shift), Some(b"\x1b_".to_vec()));
        assert_eq!(enc(ch("!"), alt_shift), Some(b"\x1b!".to_vec()), "already shifted: unchanged");
        assert_eq!(enc(ch("1"), Modifiers::ALT), Some(b"\x1b1".to_vec()), "no Shift: the digit");
    }

    #[test]
    fn ctrl_digits_follow_xterm() {
        assert_eq!(enc(ch("1"), Modifiers::CTRL), Some(b"1".to_vec()), "no control byte: the digit itself");
        assert_eq!(enc(ch("0"), Modifiers::CTRL), Some(b"0".to_vec()));
        assert_eq!(enc(ch("9"), Modifiers::CTRL), Some(b"9".to_vec()));
        assert_eq!(enc(ch("2"), Modifiers::CTRL), Some(vec![0]), "xterm: Ctrl+2 is NUL");
        assert_eq!(enc(ch("5"), Modifiers::CTRL), Some(vec![0x1d]));
        assert_eq!(enc(ch("1"), Modifiers::CTRL | Modifiers::ALT), Some(b"\x1b1".to_vec()));
    }
}
