// Who is allowed to take the physical keyboard away from whom.
//
// Karmashala has more than one thing that legitimately wants the keyboard, and
// they do not know about each other: terminal panes, text fields, and — since
// the mobile pane learned to type — a device mirror that forwards every
// keystroke to a phone. The rule they all need is the same one, so it is
// written once, here, rather than re-derived by each of them.

import 'package:flutter/widgets.dart';

/// Marks a subtree that is deliberately holding the physical keyboard.
///
/// **This exists because "is it a text field" was not the real question.**
/// `TerminalSessionsController._focusActivePane` used to guard itself with an
/// `EditableText` ancestor check, on the reasoning that opening a terminal tab
/// is not worth interrupting someone mid-sentence. Correct, but too narrow: a
/// device mirror with forwarding armed is not an [EditableText], so the guard
/// returned false and the controller took the keyboard back on the next tab or
/// pane event. Reproduced in a widget test — a click focused the mirror and the
/// first keystroke reached the device, then a post-frame `requestFocus()` moved
/// the keyboard to the terminal and the next keystroke was typed into the
/// shell. That is a keystroke going somewhere the user did not point it, which
/// is the failure this codebase treats as worst.
///
/// A plain marker widget rather than an [InheritedWidget]: nothing reads a
/// value out of it, and the question is always asked *about the focused node's
/// context* — walking up from `primaryFocus`, not down from a build. An
/// inherited value would be the wrong direction and would need a dependency
/// this has no use for.
///
/// Wrap only while the subtree is **actually** capturing. A mirror that is not
/// forwarding must not be marked, or it would pin the keyboard away from the
/// terminal for no reason.
class KeyboardCaptureScope extends StatelessWidget {
  const KeyboardCaptureScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Whether the keyboard is somewhere it would be wrong to take it from.
///
/// True for a text field the user is typing in — quick open, the search bar, a
/// composer, a dialog — and for any [KeyboardCaptureScope]. Callers that move
/// focus for their own convenience (rather than because the user asked for it)
/// check this first.
///
/// Deliberately *not* "is the focus anywhere at all": focusing the active pane
/// when a tab opens is a real convenience and must keep working. The question
/// is narrower — is the keyboard already spoken for.
bool keyboardIsSpokenFor() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null ||
      context.findAncestorWidgetOfExactType<KeyboardCaptureScope>() != null;
}
