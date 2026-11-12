import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;

import '../../../core/capabilities/capabilities.dart';
import '../../sessions/application/operate_by_default_providers.dart';
import '../../sessions/application/trust_registered_projects_providers.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Agents and accounts → New sessions: the server's "Let new
/// sessions operate Karmashala" and "Trust registered projects for agents".
/// Each row is hidden on a server that does not have it, and on a phone that
/// may not start sessions.
class NewSessionGrantSection extends ConsumerWidget {
  const NewSessionGrantSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operateOffered = ref.watch(
      capabilitiesProvider.select((c) => c.operateByDefault),
    );
    final trustOffered = ref.watch(
      capabilitiesProvider.select((c) => c.trustRegisteredProjects),
    );
    if (!operateOffered && !trustOffered) return const SizedBox.shrink();
    final on = ref.watch(operateByDefaultProvider).value ?? false;
    final trusts = ref.watch(trustRegisteredProjectsProvider).value ?? true;
    return SettingsSection(
      title: SettingsAnchor.newSessionGrant.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (operateOffered)
            SettingsRow(
              key: const ValueKey('operate-new-sessions'),
              label: 'Let new sessions operate Karmashala',
              help:
                  'Every new session may then start, message and end other '
                  'sessions and agents, so a prompt injected into one session '
                  'can reach others. This is not a sandbox. Sessions already '
                  'running keep what they have, and each session has its own '
                  'switch.',
              control: Switch(
                value: on,
                onChanged: (enabled) => _set(
                  context,
                  () => ref
                      .read(operateByDefaultActionsProvider)
                      .set(enabled: enabled),
                ),
              ),
            ),
          if (trustOffered)
            SettingsRow(
              key: const ValueKey('trust-registered-projects'),
              label: 'Trust registered projects for agents',
              help:
                  "A session starting in a project you added here skips the "
                  "agent's own trust-this-folder prompt.",
              control: Switch(
                value: trusts,
                onChanged: (enabled) => _set(
                  context,
                  () => ref
                      .read(trustRegisteredProjectsActionsProvider)
                      .set(enabled: enabled),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The switch follows the server, so a refusal leaves it where it was and
  /// only the reason needs saying.
  Future<void> _set(BuildContext context, Future<void> Function() write) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await write();
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    }
  }
}
