import 'package:flutter/material.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpAuthMethod;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// One way an ACP agent can be logged in, as it advertised it: its name, its
/// words, and how it is done — in a terminal, with an API key, or by the
/// agent itself.
class AcpLoginMethodTile extends StatelessWidget {
  const AcpLoginMethodTile({
    required this.method,
    required this.onPick,
    this.current = false,
    super.key,
  });

  final AcpAuthMethod method;
  final VoidCallback? onPick;

  /// Whether this is the method remembered now.
  final bool current;

  String get _how => method.terminal
      ? 'In a terminal'
      : method.apiKeyVariable != null
      ? 'API key'
      : 'By the agent';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        method.terminal
            ? AppIcons.terminal
            : method.apiKeyVariable != null
            ? AppIcons.keyboard
            : AppIcons.userCircle,
        size: Chrome.iconAction,
      ),
      title: Text(current ? '${method.name} (now)' : method.name),
      // How it is done sits under the name, not trailing: at a phone's width
      // and a large text scale a trailing label takes the whole row.
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_how, style: theme.textTheme.labelSmall),
          for (final line in [?method.description, ?method.completes])
            Text(line),
        ],
      ),
      onTap: onPick,
    );
  }
}
