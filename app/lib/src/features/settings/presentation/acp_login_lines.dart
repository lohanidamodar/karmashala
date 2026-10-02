import 'package:agent_cli/discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/presentation/acp_login_line.dart';
import '../../environments/application/environments_controller.dart';

/// One login line per installation; the machine is named only when there is
/// more than one.
class AcpLoginLines extends ConsumerWidget {
  const AcpLoginLines({
    required this.installs,
    required this.agentName,
    super.key,
  });

  final List<AgentInstallation> installs;
  final String agentName;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final install in installs)
        AcpLoginLine(
          installationId: install.id,
          agentName: agentName,
          machine: installs.length == 1
              ? null
              : ref.watch(environmentLabelForIdProvider(install.environmentId)),
        ),
    ],
  );
}
