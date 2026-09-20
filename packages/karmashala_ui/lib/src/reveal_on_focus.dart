import 'package:flutter/material.dart';

/// Scrolls a focused descendant back into view whichever way traversal came
/// from: `keepVisibleAtEnd` clamps to the offset and refuses to scroll back.
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
