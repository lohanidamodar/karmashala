import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';
import 'settings_layout.dart';
import 'settings_row.dart';
import 'settings_theme.dart';

export 'settings_row.dart' show SettingsNote, SettingsRuled;

/// One labelled block on the settings page, drawn as the approved board
/// draws one (N5 `.sec`): a small uppercase label 22 px under whatever came
/// before, then the section's rows flat on the page, each under its own
/// hairline. No card, no box: extracted so sections that live in their own
/// feature sit on the page looking like the ones that do not.
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
    final narrow = SettingsNarrowScope.of(context);
    final heading = Semantics(
      header: true,
      child: Text(title, style: SettingsStyles.sectionLabel(context)),
    );
    final trailing = this.trailing;
    return Padding(
      padding: EdgeInsets.only(
        top: narrow
            ? SettingsLayout.sectionTopNarrow
            : SettingsLayout.sectionTop,
      ),
      child: Column(
        // Start, not stretch: a section whose child is one button keeps the
        // button's width. Rows stretch themselves in their own columns.
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
                children: [heading, trailing],
              ),
            ),
          const SizedBox(height: SettingsLayout.sectionLabelGap),
          child,
        ],
      ),
    );
  }
}

/// One entry of a list on a settings page — an installation, an environment, a
/// host. The board has no cards: a list entry is a row, so this is a row's
/// frame — the hairline above and the row's padding — around content that is
/// more than a label and a control. Every settings "card" is this one, so none
/// drifts to its own margin, padding or fill.
class SettingsCard extends StatelessWidget {
  const SettingsCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => SettingsRuled(child: child);
}
