import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../core/probe/probe_mode.dart';

/// A strip above the whole app that a probe cannot be mistaken without: what
/// it is, where its data lives, and what it deliberately does not do.
///
/// **No `Tooltip` in here, on purpose.** The strip is mounted from
/// `MaterialApp.builder`, above the Navigator, so that no route can cover it —
/// and a `Tooltip` shows itself through an `Overlay`, which only the Navigator
/// provides. Hovering one here threw "No Overlay widget found" and left the
/// probe's window blank. Anything that needs an `Overlay` (tooltips, menus,
/// dialogs) cannot live in this widget; the full list goes to the semantics
/// label instead, and the visible text carries what a glance needs.
class ProbeBanner extends StatelessWidget {
  const ProbeBanner({super.key, required this.probe, required this.child});

  final ProbeMode probe;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!probe.enabled) return child;
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: scheme.onErrorContainer);
    return Column(
      children: [
        Material(
          key: const ValueKey('probe_banner'),
          color: scheme.errorContainer,
          child: Semantics(
            container: true,
            label:
                'Probe instance. Disabled in a probe: '
                '${ProbeMode.disabledEffects.join('; ')}. '
                'Agents launched here still fire the hooks the real app '
                'installed, so their live status reaches the real app, not '
                'this one.',
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.xs,
              ),
              child: Row(
                children: [
                  Icon(AppIcons.warning, color: scheme.onErrorContainer),
                  const SizedBox(width: Insets.sm),
                  Text(
                    'PROBE',
                    style: style?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      'Test instance — not your Karmashala. Data: '
                      '${probe.dataDirectory ?? '(none)'} · hooks, skills, '
                      'autostart, hotkey and remote access are off; agent '
                      'status from hooks is not reported here.',
                      style: style,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
