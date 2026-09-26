import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

/// A path field and the buttons that fill it — Browse, Choose app, Save.
///
/// On a settings page the buttons sit beside the field when there is room and
/// drop under it when there is not ([PathFieldRow.new]). Inside an
/// `AlertDialog`, whose content is sized by intrinsics and so cannot hold a
/// `LayoutBuilder`, [PathFieldRow.inDialog] keeps them beside the field
/// without measuring: a dialog body is already a known, narrow width.
class PathFieldRow extends StatelessWidget {
  const PathFieldRow({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.actions = const [],
    this.dense = true,
    super.key,
  }) : _measures = true;

  /// The non-measuring variant for dialog content: field, then buttons, on one
  /// line.
  const PathFieldRow.inDialog({
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.actions = const [],
    this.dense = false,
    super.key,
  }) : _measures = false;

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Buttons, in reading order.
  final List<Widget> actions;

  /// A dense field, as settings rows draw them; dialogs draw full height.
  final bool dense;

  final bool _measures;

  /// Below this width at 1x text the buttons go under the field: a field and
  /// two worded buttons do not share a phone's width or 150% text.
  static const stackBelow = 520.0;

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      decoration: InputDecoration(
        isDense: dense,
        labelText: label,
        hintText: hint,
        helperText: helper,
        errorText: errorText,
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
    if (actions.isEmpty) return field;

    if (!_measures) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: field),
          for (final action in actions) ...[
            const SizedBox(width: Insets.sm),
            action,
          ],
        ],
      );
    }
    return StackWhenNarrow(
      breakpoint: stackBelow,
      spacing: Insets.sm,
      stackedAlignment: CrossAxisAlignment.stretch,
      leading: field,
      trailing: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        children: actions,
      ),
    );
  }
}
