import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// One saved thing in a list — a variable, a snippet, an automation on their
/// settings pages: a header, what it is, and its worded verbs. The three pages
/// drew three near-copies of this.
class ItemCard extends StatelessWidget {
  const ItemCard({
    required this.title,
    this.icon,
    this.trailing,
    this.details = const [],
    this.actions = const [],
    this.footer = const [],
    super.key,
  });

  /// The item's name, styled by the caller: a variable's is mono.
  final Widget title;

  /// Drawn at [Chrome.iconTitle] in the tertiary colour, beside [title].
  final IconData? icon;

  /// At the end of the header — a switch, say.
  final Widget? trailing;

  /// What the item is, under the header.
  final List<Widget> details;

  /// Worded buttons, in one wrapping row: this is a settings form.
  final List<Widget> actions;

  /// Under the actions — an automation's recent runs.
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon case final glyph?) ...[
                  Padding(
                    // Optical alignment with the title's cap height.
                    padding: const EdgeInsets.only(top: Insets.xxs),
                    child: Icon(
                      glyph,
                      size: Chrome.iconTitle,
                      color: scheme.tertiary,
                    ),
                  ),
                  const SizedBox(width: Insets.sm),
                ],
                Expanded(child: title),
                ?trailing,
              ],
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: Insets.xs),
              ...details,
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Insets.sm),
              Wrap(
                spacing: Insets.xs,
                runSpacing: Insets.xs,
                children: actions,
              ),
            ],
            ...footer,
          ],
        ),
      ),
    );
  }
}
