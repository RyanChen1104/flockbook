//! The flowing, virtualized, selectable conversation: model (`model`), shaping (`shape`) and the widget (`widget`).
//! Selection is keyed by stable row id plus byte offset and lives in app state (`SelState`).

pub mod model;
pub mod shape;
pub mod widget;

pub use model::*;
pub use widget::{Flow, FlowEvent, FlowKey, Probe};
