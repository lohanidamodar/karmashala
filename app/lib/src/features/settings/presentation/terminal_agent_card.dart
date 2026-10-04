import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import 'agent_label.dart';
import 'settings_catalog.dart';
import 'settings_page_body.dart' show SettingsAnchorScope;
import 'terminal_agent_row.dart';

/// **One terminal agent as a card that opens**: folded, the
/// [TerminalAgentRow]; open, [body] — the agent's machines, executables,
/// accounts and behaviour — indented under it. Folded by default, and opened
/// by a deep link to one of its [anchors] so the link lands on what it named.
class TerminalAgentCard extends ConsumerStatefulWidget {
  const TerminalAgentCard({
    required this.descriptor,
    required this.installs,
    required this.body,
    this.chatInstalls = const [],
    this.anchors = const {},
    super.key,
  });

  final AgentDescriptor descriptor;
  final List<AgentInstallation> installs;

  /// The installations of the agent's chat form, when it has one.
  final List<AgentInstallation> chatInstalls;
  final Widget body;
  final Set<SettingsAnchor> anchors;

  @override
  ConsumerState<TerminalAgentCard> createState() => _TerminalAgentCardState();
}

class _TerminalAgentCardState extends ConsumerState<TerminalAgentCard> {
  bool _open = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final revealing = SettingsAnchorScope.revealingOf(context);
    if (revealing != null && widget.anchors.contains(revealing)) _open = true;
  }

  @override
  Widget build(BuildContext context) {
    final name = agentLabel(ref, widget.descriptor.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TerminalAgentRow(
          descriptor: widget.descriptor,
          installs: widget.installs,
          chatInstalls: widget.chatInstalls,
          trailing: IconButton(
            tooltip: _open ? 'Collapse $name' : 'Expand $name',
            icon: Icon(
              _open ? AppIcons.caretUp : AppIcons.caretDown,
              size: Chrome.iconAction,
            ),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _open = !_open),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(left: Insets.lg, bottom: Insets.md),
            child: widget.body,
          ),
      ],
    );
  }
}
