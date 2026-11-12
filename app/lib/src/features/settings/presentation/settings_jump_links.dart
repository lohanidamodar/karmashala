import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/capabilities/capabilities.dart';
import 'settings_catalog.dart';
import 'settings_page_body.dart' show SettingsAnchorScope;

/// **The sections of a long page, as links under its blurb**: one chip per
/// section this client shows, each scrolling to it. Drawn only on a page with
/// more than [fewest] sections; a short page is read at a glance.
class SettingsJumpLinks extends ConsumerWidget {
  const SettingsJumpLinks({required this.page, super.key});

  final SettingsSectionId page;

  /// A page with this many sections or fewer draws no links.
  static const fewest = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    final anchors = [
      for (final anchor in page.anchors)
        if (anchor.shownWith(caps)) anchor,
    ];
    if (anchors.length <= fewest) return const SizedBox.shrink();
    final keys = {
      for (final anchor in anchors)
        anchor: SettingsAnchorScope.keyFor(context, anchor),
    };
    final theme = Theme.of(context);
    final touch = UiDensity.of(context).isTouch;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        children: [
          for (final anchor in anchors)
            ActionChip(
              key: ValueKey('settings-jump-${anchor.name}'),
              label: Text(anchor.title),
              labelStyle: theme.textTheme.labelSmall,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: touch
                  ? MaterialTapTargetSize.padded
                  : MaterialTapTargetSize.shrinkWrap,
              labelPadding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
              onPressed: () {
                final target = keys[anchor]?.currentContext;
                if (target == null) return;
                Scrollable.ensureVisible(target);
              },
            ),
        ],
      ),
    );
  }
}
