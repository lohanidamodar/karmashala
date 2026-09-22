import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';

import '../core/probe/probe_mode.dart';

/// A strip above the whole app that a probe cannot be mistaken without: what
/// it is, where its data lives, and what it deliberately does not do.
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
          child: Tooltip(
            message:
                'Disabled in a probe: '
                '${ProbeMode.disabledEffects.join('; ')}.\n'
                'Agents launched here still fire the hooks the real app '
                'installed, so their live status reaches the real app, not '
                'this one.',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    AppIcons.warning,
                    color: scheme.onErrorContainer,
                    semanticLabel: 'Probe instance',
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'PROBE',
                    style: style?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Test instance — not your Karmashala. Data: '
                      '${probe.dataDirectory ?? '(none)'} · hooks, skills, '
                      'autostart, hotkey and remote access are off; agent '
                      'status from hooks is not reported here.',
                      style: style,
                      maxLines: 1,
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
