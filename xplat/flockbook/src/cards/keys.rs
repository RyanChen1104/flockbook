//! A transparent wrapper that turns key presses into messages for a card, while the card owns the keyboard.
//!
//! iced has no focus-free key hook for a widget tree (only subscriptions, which the headless Simulator does not
//! run), so the cards wrap themselves in this. It draws and lays out exactly like its content. The parent passes it
//! every keyboard event, so it keeps its own rule for when a key is the card's: the card must own the keyboard (see
//! [`State`]), no widget below may have used the key, and the closure must return `Some`. Safety: a key that goes to
//! a text field (composer, "Other") never reaches the card's shortcuts, and one key makes at most one message.

use iced::advanced::layout::{self, Layout};
use iced::advanced::widget::operation::Focusable;
use iced::advanced::widget::{tree, Operation, Tree};
use iced::advanced::{mouse, overlay, renderer, Clipboard, Shell, Widget};
use iced::{keyboard, Element, Event, Length, Rectangle, Size, Vector};

/// The widget's own state: who the keys are for, and whether the card owns the keyboard.
///
/// Same rule as the Swift app: a card has the keyboard after the owner clicked it (a question card also gets it when it
/// appears, like Swift `onAppear { focus = .card }`). A click anywhere else takes it away. A new card (another `scope`)
/// starts from its default.
struct State {
    scope: String,
    focused: bool,
}

pub struct KeyCatcher<'a, M, F> {
    content: Element<'a, M>,
    scope: String,
    default_focus: bool,
    on_key: F,
}

/// Wraps `content`. `scope` names the card (its key): the keyboard focus resets when it changes. `default_focus` says if a
/// new card owns the keyboard at once. `on_key(event, field_focused)` runs only for a key press that (1) happens while the
/// card owns the keyboard, and (2) no widget below handled. `field_focused` is true when a text field inside `content`
/// had the focus when the key came (the composer, the "Other" field): the card must then leave the key alone.
pub fn catch<'a, M, F>(content: impl Into<Element<'a, M>>, scope: impl Into<String>, default_focus: bool, on_key: F) -> KeyCatcher<'a, M, F>
where
    F: Fn(&keyboard::Event, bool) -> Option<M> + 'a,
{
    KeyCatcher { content: content.into(), scope: scope.into(), default_focus, on_key }
}

/// Finds out if any focusable widget (text input, text editor) in a tree has the focus.
struct AnyFocused(bool);

impl Operation<()> for AnyFocused {
    fn traverse(&mut self, operate: &mut dyn FnMut(&mut dyn Operation<()>)) {
        operate(self);
    }
    fn focusable(&mut self, _id: Option<&iced::widget::Id>, _bounds: Rectangle, state: &mut dyn Focusable) {
        if state.is_focused() {
            self.0 = true;
        }
    }
}

impl<'a, M, F> Widget<M, iced::Theme, iced::Renderer> for KeyCatcher<'a, M, F>
where
    F: Fn(&keyboard::Event, bool) -> Option<M>,
{
    fn size(&self) -> Size<Length> {
        self.content.as_widget().size()
    }
    fn size_hint(&self) -> Size<Length> {
        self.content.as_widget().size_hint()
    }
    fn layout(&mut self, tree: &mut Tree, renderer: &iced::Renderer, limits: &layout::Limits) -> layout::Node {
        self.content.as_widget_mut().layout(&mut tree.children[0], renderer, limits)
    }
    fn draw(&self, tree: &Tree, renderer: &mut iced::Renderer, theme: &iced::Theme, style: &renderer::Style, layout: Layout<'_>, cursor: mouse::Cursor, viewport: &Rectangle) {
        self.content.as_widget().draw(&tree.children[0], renderer, theme, style, layout, cursor, viewport);
    }
    fn tag(&self) -> tree::Tag {
        tree::Tag::of::<State>()
    }
    fn state(&self) -> tree::State {
        tree::State::new(State { scope: self.scope.clone(), focused: self.default_focus })
    }
    fn children(&self) -> Vec<Tree> {
        vec![Tree::new(&self.content)]
    }
    fn diff(&self, tree: &mut Tree) {
        let st = tree.state.downcast_mut::<State>();
        if st.scope != self.scope {
            st.scope = self.scope.clone();
            st.focused = self.default_focus;
        }
        tree.diff_children(std::slice::from_ref(&self.content));
    }
    fn operate(&mut self, tree: &mut Tree, layout: Layout<'_>, renderer: &iced::Renderer, operation: &mut dyn Operation) {
        self.content.as_widget_mut().operate(&mut tree.children[0], layout, renderer, operation);
    }
    fn update(&mut self, tree: &mut Tree, event: &Event, layout: Layout<'_>, cursor: mouse::Cursor, renderer: &iced::Renderer, clipboard: &mut dyn Clipboard, shell: &mut Shell<'_, M>, viewport: &Rectangle) {
        // Ask BEFORE the children see the key: Esc makes a text field let go of the focus, and the key must still count
        // as "typed in a field".
        let key = match event {
            Event::Keyboard(k @ keyboard::Event::KeyPressed { .. }) => Some(k),
            _ => None,
        };
        let field_focused = key.is_some() && {
            let mut probe = AnyFocused(false);
            self.content.as_widget_mut().operate(&mut tree.children[0], layout, renderer, &mut probe);
            probe.0
        };
        self.content.as_widget_mut().update(&mut tree.children[0], event, layout, cursor, renderer, clipboard, shell, viewport);
        if let Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)) = event {
            tree.state.downcast_mut::<State>().focused = cursor.is_over(layout.bounds());
        }
        if let Some(k) = key {
            // A key a child already used (typing in a field, the composer's own Enter) is not ours.
            if shell.is_event_captured() || !tree.state.downcast_ref::<State>().focused {
                return;
            }
            if let Some(m) = (self.on_key)(k, field_focused) {
                shell.publish(m);
                shell.capture_event();
            }
        }
    }
    fn mouse_interaction(&self, tree: &Tree, layout: Layout<'_>, cursor: mouse::Cursor, viewport: &Rectangle, renderer: &iced::Renderer) -> mouse::Interaction {
        self.content.as_widget().mouse_interaction(&tree.children[0], layout, cursor, viewport, renderer)
    }
    fn overlay<'b>(&'b mut self, tree: &'b mut Tree, layout: Layout<'b>, renderer: &iced::Renderer, viewport: &Rectangle, translation: Vector) -> Option<overlay::Element<'b, M, iced::Theme, iced::Renderer>> {
        self.content.as_widget_mut().overlay(&mut tree.children[0], layout, renderer, viewport, translation)
    }
}

impl<'a, M: 'a, F: Fn(&keyboard::Event, bool) -> Option<M> + 'a> From<KeyCatcher<'a, M, F>> for Element<'a, M> {
    fn from(w: KeyCatcher<'a, M, F>) -> Self {
        Element::new(w)
    }
}
