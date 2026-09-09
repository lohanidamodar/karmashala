// Forward Tab traversal cannot scroll backwards, and a lazy list makes that a
// bug rather than a curiosity.

import 'package:flutter/material.dart';

/// Scrolls a focused descendant back into view, whichever direction the
/// traversal arrived from.
///
/// **Flutter already does half of this, and the half it does is the wrong half
/// for a list.** `FocusTraversalPolicy` calls [Scrollable.ensureVisible] on
/// every stop it moves to, with [ScrollPositionAlignmentPolicy.keepVisibleAtEnd]
/// going forward — and that policy clamps its target to the current offset, so
/// it *refuses to scroll backwards*. Rows a `ListView` keeps laid out inside its
/// cache extent **above** the viewport are ordinary focus stops, and forward Tab
/// wrapping round to one of them moves nothing: the row takes the focus off
/// screen, which is the "focusable but not visible" failure the window matrix
/// exists to catch.
///
/// Measured on a 30-row `ListView.builder` in a 720x560 window: after tabbing to
/// the last row, five more Tabs land on rows whose top edge is -280, -224, -168,
/// -112 and -56. With this wrapper the same five land at 0, 56, 112, 168 and 224.
///
/// **The two clamped policies compose into the unclamped move.**
/// `keepVisibleAtStart` only ever scrolls back and `keepVisibleAtEnd` only ever
/// scrolls forward, so running both leaves an already-visible child alone and
/// brings an off-screen one in from whichever side it is on — without the
/// jump-to-the-middle that a plain `explicit` alignment would give every row.
class RevealOnFocus extends StatefulWidget {
  const RevealOnFocus({required this.child, super.key});

  final Widget child;

  @override
  State<RevealOnFocus> createState() => _RevealOnFocusState();
}

class _RevealOnFocusState extends State<RevealOnFocus> {
  @override
  Widget build(BuildContext context) {
    // Not a stop of its own: it neither takes focus nor appears in the ring, it
    // only listens for a descendant taking it.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onFocusChange,
      child: widget.child,
    );
  }

  void _onFocusChange(bool hasFocus) {
    if (!hasFocus || !mounted) return;
    // A row focused before it has been laid out has nothing to reveal, and
    // `ensureVisible` asserts on it.
    if (context.findRenderObject() == null) return;
    for (final policy in const [
      ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    ]) {
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: policy,
        // The framework's own traversal jumps rather than animates; matching it
        // keeps one Tab from racing the next.
        duration: Duration.zero,
      );
    }
  }
}
