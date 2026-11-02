import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/bot_providers.dart';

/// Settings → Agents and accounts → Bot: which agent the bot runs on. Hidden on
/// a server with no bot, and on a phone that may not start sessions. Kept on
/// the server, so every client reads the same value.
class BotSettingsSection extends ConsumerStatefulWidget {
  const BotSettingsSection({super.key});

  @override
  ConsumerState<BotSettingsSection> createState() => _BotSettingsSectionState();
}

class _BotSettingsSectionState extends ConsumerState<BotSettingsSection> {
  /// Moved by a refusal, which builds the field anew at what the server
  /// holds: a dropdown shows its pick before the server has answered.
  var _refusals = 0;

  @override
  Widget build(BuildContext context) {
    final offered = ref.watch(capabilitiesProvider.select((c) => c.manageBot));
    final state = ref.watch(botStateProvider);
    if (!offered || state == null) return const SizedBox.shrink();
    return SettingsSection(
      title: SettingsAnchor.bot.heading,
      child: SettingsRow(
        key: const ValueKey('bot-setting'),
        label: 'Agent the bot runs on',
        help: state.agents.isEmpty
            ? 'No agent the bot can run on is installed on this server. It '
                  'needs an agent with a chat form.'
            : 'Only agents with a chat form can run it. A conversation under '
                  'way carries on with the new agent. It cannot change while '
                  'a turn runs.',
        control: state.agents.isEmpty
            ? const SizedBox.shrink()
            : DropdownButtonFormField<String?>(
                // Follows the server: a refusal or another client's choice
                // redraws it at what the server holds.
                key: ValueKey('bot-setting-${state.agentSetting}-$_refusals'),
                initialValue: state.agentSetting,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(child: Text('Default agent')),
                  for (final agent in state.agents)
                    DropdownMenuItem(
                      value: agent.agentId,
                      child: Text(agent.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _set,
              ),
      ),
    );
  }

  Future<void> _set(String? id) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(botActionsProvider).setAgent(id);
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
      if (mounted) setState(() => _refusals++);
    }
  }
}
