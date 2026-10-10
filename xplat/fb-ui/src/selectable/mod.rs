//! Cross-block text selection over a rendered conversation (SelectableDoc).
//!
//! Moved in from the `spike-select` crate (Phase A gate 1). `demo_app` is the minimal Elm app the tests drive.

pub mod demo_app;
pub mod flow;
pub mod model;
pub mod widget;
pub mod words;

pub use model::{build_blocks, Block, Content, Kind, Message, Pos, Role, Selection};
pub use widget::{Geometry, SelectableDoc};
