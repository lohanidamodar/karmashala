import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:karmashala_ui/tokens.dart';

/// How a sheet lifts off the workbench it covers (board N4, Medium): one
/// deep shadow cast away from the edge it comes in from — a sheet over a live
/// pane has to read as *over* it, which a tone step alone does not do.
const double _sheetShadowOffset = 12;
const double _sheetShadowBlur = 30;
const double _sheetShadowAlpha = 0.45;

/// **A sheet over the workbench** (UI overhaul spec §5, Medium and Compact):
/// the sidebar or the context panel, drawn on top of the workbench instead of
/// beside it once the window is too narrow to share its width.
///
/// It slides a short way in from its own edge and fades, both collapsed to
/// nothing under reduced motion ([Motion.of]). While open it holds the focus,
/// so Esc reaches [onDismiss] however the sheet was opened — by the strip, a
/// chord or a menu — and gives the focus back to whatever had it on close.
class ShellSlideOver extends StatefulWidget {
  const ShellSlideOver({
    required this.open,
    required this.fromStart,
    required this.onDismiss,
    required this.child,
    this.animateOut = true,
    super.key,
  });

  final bool open;

  /// False for a sheet whose content empties the moment it closes (the
  /// context panel draws nothing once collapsed): fading out an empty sheet
  /// would only show a blank slab leaving.
  final bool animateOut;

  /// True for a sheet on the leading edge (the sidebar), false for the
  /// trailing one (the context panel).
  final bool fromStart;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<ShellSlideOver> createState() => _ShellSlideOverState();
}

class _ShellSlideOverState extends State<ShellSlideOver>
    with SingleTickerProviderStateMixin {
  /// A short slide, not the sheet's whole width: the eye needs a direction,
  /// not a journey across a pane it was reading.
  static const _slide = 0.06;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.open ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Motion.enter,
    reverseCurve: Motion.exit,
  );
  late final Animation<Offset> _offset = Tween<Offset>(
    begin: Offset(widget.fromStart ? -_slide : _slide, 0),
    end: Offset.zero,
  ).animate(_curve);

  final _focus = FocusNode(debugLabel: 'narrow sheet');

  /// What had the focus before the sheet took it — usually the terminal.
  FocusNode? _previous;

  @override
  void initState() {
    super.initState();
    if (widget.open) _takeFocus();
  }

  @override
  void didUpdateWidget(ShellSlideOver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    final motion = Motion.of(context);
    _controller
      ..duration = motion.emphasisIn
      ..reverseDuration = motion.emphasisOut;
    if (widget.open) {
      _controller.forward();
      _takeFocus();
    } else {
      if (widget.animateOut) {
        _controller.reverse();
      } else {
        _controller.value = 0;
      }
      _giveFocusBack();
    }
  }

  /// After the frame, so the sheet's own content has mounted — and only when
  /// nothing inside it took the focus first (a filter field, say).
  void _takeFocus() {
    final before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.open || _focus.hasFocus) return;
      _previous = before;
      _focus.requestFocus();
    });
  }

  void _giveFocusBack() {
    final previous = _previous;
    _previous = null;
    if (!_focus.hasFocus) return;
    if (previous != null &&
        previous.context != null &&
        previous.canRequestFocus) {
      previous.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    return AnimatedBuilder(
      animation: _controller,
      // Gone once closed, not merely transparent: a sheet at opacity zero
      // would still take the pointer over the workbench.
      builder: (context, sheet) => _controller.isDismissed
          ? const SizedBox.shrink()
          : FadeTransition(
              opacity: _curve,
              child: SlideTransition(position: _offset, child: sheet),
            ),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        // The shadow, not a hairline, parts the sheet from the workbench.
        child: DecoratedBox(
          decoration: BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: _sheetShadowAlpha),
                offset: Offset(
                  widget.fromStart ? _sheetShadowOffset : -_sheetShadowOffset,
                  0,
                ),
                blurRadius: _sheetShadowBlur,
              ),
            ],
          ),
          child: Material(
            // The sheet's own content paints its tone; this is the ground.
            color: widget.fromStart ? tones.side : tones.panel,
            clipBehavior: Clip.hardEdge,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// What lies behind an open sheet. A click on it is a click outside the
/// sheet, so it closes the sheet — and goes no further, rather than also
/// landing on whatever pane was under it. Clear, not a wash (board N4): the
/// sheet's shadow already says which is in front, and the workbench stays
/// fully readable beside it.
class ShellOverlayScrim extends StatelessWidget {
  const ShellOverlayScrim({required this.onDismiss, super.key});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Close',
    button: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: const SizedBox.expand(),
    ),
  );
}
