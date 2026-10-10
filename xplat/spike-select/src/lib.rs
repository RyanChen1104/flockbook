//! Gate 1 spike: cross-block text selection over a rendered conversation.

pub mod app;
pub mod model;
pub mod widget;

pub use model::{Block, Kind, Message, Pos, Role, Selection};
pub use widget::{Geometry, SelectableDoc};
