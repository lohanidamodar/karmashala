import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// One labelled part of the New session / New project dialog (UI overhaul
/// spec §5): a small tracked label over its fields, the same gap before every
/// part. Both tabs of the dialog draw their parts with it, so switching tabs
/// does not change the rhythm under the eye.
class NewDialogSection extends StatelessWidget {
  const NewDialogSection({
    required this.label,
    required this.child,
    this.first = false,
    super.key,
  });

  final String label;
  final Widget child;

  /// The first part sits straight under the Session | Project switch, which
  /// brings its own gap.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              label.toUpperCase(),
              style: theme.textTheme.labelSmall
                  ?.merge(Chrome.groupLabel)
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: Insets.sm),
          child,
        ],
      ),
    );
  }
}

/// The dialog's primary button label with its chord beside it, dimmed: the
/// shortcut is learnt where the hand already goes, not from a helper line
/// under one field.
class LabelWithChord extends StatelessWidget {
  const LabelWithChord({required this.label, required this.chord, super.key});

  final String label;
  final String chord;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: Insets.sm),
        Text(
          chord,
          style: Chrome.paneLabel.copyWith(
            color: style.color?.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
