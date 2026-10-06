import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// Every search or filter box in the app: a [TextField] that draws a Clear
/// button at its end while it holds text. Clearing empties it, reports `''`
/// through [onChanged] and keeps focus in the field.
///
/// A guard test refuses a search box built on a bare [TextField], so a new one
/// cannot ship without the button.
class SearchField extends StatefulWidget {
  const SearchField({
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.onChanged,
    this.onSubmitted,
    this.style,
    this.autofocus = false,
    this.enabled,
    this.clearOnEscape,
    super.key,
  });

  /// Null keeps one of its own.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// The field's look; its `suffixIcon`, if any, stays beside the button.
  final InputDecoration decoration;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextStyle? style;
  final bool autofocus;
  final bool? enabled;

  /// Whether Escape clears a field that holds text. Null clears unless the
  /// field is in a dialog or sheet, whose Escape closes it; false where Escape
  /// already closes something else, such as a find bar.
  final bool? clearOnEscape;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  var _inPopup = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!(widget.clearOnEscape ?? !_inPopup) ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape ||
        _controller.text.isEmpty) {
      return KeyEventResult.ignored;
    }
    _clear();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // The opaque aspect only: a popup opening over the page must not rebuild it.
    _inPopup = ModalRoute.opaqueOf(context) == false;
    final density = UiDensity.of(context);
    final own = widget.decoration.suffixIcon;
    final enabled = widget.enabled ?? true;
    final suffix = ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final button = _controller.text.isEmpty || !enabled
            ? null
            : IconButton(
                tooltip: 'Clear',
                visualDensity: density.controlDensity,
                padding: EdgeInsets.zero,
                constraints: density.iconConstraints(Chrome.control),
                iconSize: density.iconSize(Chrome.iconSmall),
                icon: const Icon(AppIcons.x),
                onPressed: _clear,
              );
        if (button == null) return own ?? const SizedBox.shrink();
        if (own == null) return button;
        return Row(mainAxisSize: MainAxisSize.min, children: [button, own]);
      },
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: widget.autofocus,
        enabled: widget.enabled,
        style: widget.style,
        decoration: widget.decoration.copyWith(
          suffixIcon: suffix,
          suffixIconConstraints:
              widget.decoration.suffixIconConstraints ?? const BoxConstraints(),
        ),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}
