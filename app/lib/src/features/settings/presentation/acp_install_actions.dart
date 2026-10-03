import 'package:agent_cli/descriptors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../agents/application/acp_install_controller.dart';
import '../../environments/application/environments_controller.dart';

/// **"Install on `<machine>`"**, once per machine a registry-shipped ACP agent
/// is not installed on and Karmashala can install into (this one and its WSL
/// distributions): the step under way while it runs, the server's words
/// when it fails. Nothing for an agent the registry does not ship as a
/// binary.
class AcpInstallActions extends ConsumerWidget {
  const AcpInstallActions({
    required this.descriptor,
    required this.installedOn,
    super.key,
  });

  final AgentDescriptor descriptor;

  /// The environment ids the agent is already installed in.
  final Set<String> installedOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registryId = descriptor.acp?.registryId;
    if (registryId == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final state = ref.watch(acpInstallControllerProvider);
    final targets = [
      for (final environment in ref.watch(environmentsControllerProvider))
        if (!installedOn.contains(environment.id) &&
            acpInstallReaches(environment.kind))
          environment,
    ];
    if (targets.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final environment in targets) ...[
          if (state.failureOf(registryId, environment.id) case final words?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: DesktopErrorBanner(words),
            ),
          switch (state.stepOf(registryId, environment.id)) {
            final step? => Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const InlineSpinner(),
                  const SizedBox(width: Insets.sm),
                  Text(
                    '${describeAcpInstallStep(step)} on ${environment.name}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            null => TextButton.icon(
              key: ValueKey('acp-install-${descriptor.id}-${environment.id}'),
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onPressed: () => ref
                  .read(acpInstallControllerProvider.notifier)
                  .install(
                    registryId: registryId,
                    environmentId: environment.id,
                    agentId: descriptor.id,
                  )
                  // The failure is on the row already, in the server's words.
                  .then((_) {}, onError: (_) {}),
              icon: const Icon(AppIcons.downloadSimple, size: Chrome.icon),
              label: Text('Install on ${environment.name}'),
            ),
          },
        ],
      ],
    );
  }
}
