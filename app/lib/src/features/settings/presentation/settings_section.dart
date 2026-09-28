import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'settings_layout.dart';

/// One labelled block on the settings page. Extracted so sections that live in
/// their own feature sit on the page looking like the ones that do not.
///
/// The header is a [Wrap], not a row: a trailing action ("Add a host", a
/// switch, a pair of buttons) sits at the right while it fits beside the
/// title, and drops under it on a narrow pane instead of squeezing the title
/// to nothing and overflowing. It needs no width of its own, so the section is
/// safe wherever it is measured, intrinsics included.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = SettingsNarrowScope.of(context);
    final heading = Text(
      title,
      style: theme.textTheme.labelSmall?.merge(Chrome.groupLabel),
    );
    return Padding(
      padding: EdgeInsets.only(bottom: narrow ? Insets.lg : Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trailing == null)
            heading
          else
            // Full width, or the wrap shrinks to its runs and spaceBetween has
            // no room to push the action right.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                children: [heading, trailing!],
              ),
            ),
          const SizedBox(height: Insets.sm),
          child,
        ],
      ),
    );
  }
}

/// One card on a settings page — an installation, an environment, a host.
/// Every settings card is this one, so none drifts to its own margin or
/// padding; on a narrow page it gives its content a little more of the width.
class SettingsCard extends StatelessWidget {
  const SettingsCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final narrow = SettingsNarrowScope.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: EdgeInsets.all(narrow ? Insets.sm : Insets.md),
        child: child,
      ),
    );
  }
}
