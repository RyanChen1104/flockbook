//! A terminal view for iced: a grid fed with herdr frames, a palette from the theme tokens, key encoding, and the widget.
//!
//! - [`grid`]: `TermGrid` feeds frame bytes into `alacritty_terminal` and hands out an owned [`GridSnapshot`].
//! - [`palette`]: ANSI 16/256/truecolor to iced colors, light and dark.
//! - [`keys`]: pure key to xterm byte encoding.
//! - [`selection`]: linear text selection over a snapshot (local to the widget).
//! - [`widget`]: the custom widget. It draws a snapshot and reports keys, IME text, paste, wheel and size.
//!
//! We feed bytes and never spawn a pty, so the crate is used without its default features.

pub mod grid;
pub mod keys;
pub mod palette;
pub mod selection;
pub mod widget;

pub use grid::{CellView, CursorShape, CursorView, GridSnapshot, TermColor, TermGrid};
pub use palette::TermPalette;
pub use selection::Selection;
pub use widget::{Terminal, CELL_H, CELL_W, PAD};
