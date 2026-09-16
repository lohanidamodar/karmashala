import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// One labelled block on the settings page. Extracted so sections that live in
/// their own feature sit on the page looking like the ones that do not.
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
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelSmall?.merge(Chrome.groupLabel),
                ),
              ),
              ?trailing,
            ],
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
/// padding.
class SettingsCard extends StatelessWidget {
  const SettingsCard({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      child: Padding(padding: const EdgeInsets.all(Insets.md), child: child),
    );
  }
}
