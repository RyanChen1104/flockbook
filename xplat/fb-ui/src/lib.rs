//! fb-ui: reusable widgets and design tokens for Flockbook (iced 0.14).
//!
//! - [`theme`]: DESIGN.md tokens (light + dark), type scale, spacing, radii, shadows.
//! - [`fonts`]: bundled Inter + JetBrains Mono and the CJK fallback rules.
//! - [`icons`]: Lucide icons via svg, stroke 1.75, sizes 14/16/20.
//! - [`status`]: the four status symbols (14 pt) and 6 pt dots.
//! - [`selectable`]: `SelectableDoc`, cross-block text selection (from spike-select).
//! - [`virt`] and [`keyed_body`]: virtual list window math and the keyed column (from spike-virt / rmdv).

pub mod fonts;
pub mod highlight;
pub mod icons;
pub mod keyed_body;
pub mod selectable;
pub mod status;
pub mod theme;
pub mod virt;

pub use status::StatusKind;
pub use theme::{Mode, Tokens};
