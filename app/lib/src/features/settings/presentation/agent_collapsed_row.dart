import 'package:flutter/material.dart';
import 'package:karmashala_ui/tokens.dart';

import 'agent_health.dart';
import 'environment_chips.dart';
import 'settings_row.dart';
import 'settings_theme.dart';

/// **One agent, folded to a line**: its health glyph, its name, a chip per
/// machine it is installed on, and one quiet line under them — a version,
/// how it is launched, or why there is nothing to show. The chips wrap under
/// the name on a narrow row rather than squeezing it.
class AgentCollapsedRow extends StatelessWidget {
  const AgentCollapsedRow({
    required this.name,
    required this.health,
    required this.environmentIds,
    this.logo,
    this.detail,
    this.trailing,
    this.tooltip,
    super.key,
  });

  final String name;
  final AgentHealthReading health;
  final Iterable<String> environmentIds;

  /// The agent's own mark, before its name.
  final Widget? logo;

  /// The line under the name, in the row-help hand.
  final Widget? detail;

  /// At the row's right: a fold button, an edit pair.
  final Widget? trailing;

  /// Said over the whole row — what kind of agent this is.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    final trailing = this.trailing;
    Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, right: Insets.sm),
          child: AgentHealthGlyph(reading: health),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ?logo,
                  Text(name, style: SettingsStyles.rowLabel(context)),
                  EnvironmentChips(environmentIds: environmentIds),
                ],
              ),
              if (detail != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: DefaultTextStyle.merge(
                    style: SettingsStyles.rowHelp(context),
                    child: detail,
                  ),
                ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Insets.sm), trailing],
      ],
    );
    if (tooltip != null) row = Tooltip(message: tooltip!, child: row);
    return SettingsRuled(child: row);
  }
}
