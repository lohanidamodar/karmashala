import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh_host/host.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/presentation/settings_notice.dart';
import '../application/host_install_controller.dart';
import 'copyable_command.dart';
import 'privileged_command_block.dart';

/// A deploy that put no usable session host on [host], as every surface shows
/// it: one sentence, the remedy, and the button that carries it out — plus the
/// command when the remedy is one. Never an exception's own `toString`.
class HostDeployFailureNotice extends ConsumerWidget {
  const HostDeployFailureNotice({
    required this.host,
    required this.deployment,
    this.onInstalled,
    this.closeDialogFirst = false,
    this.debugRun = kDebugMode,
    super.key,
  });

  final SshHost host;
  final HostDeployment deployment;

  /// Called once the button's deploy ended ready, so the surface can do again
  /// what it was doing when it met the failure.
  final VoidCallback? onInstalled;

  /// See [PrivilegedCommandBlock.closeDialogFirst].
  final bool closeDialogFirst;

  /// Whether to offer the command that builds a missing bundle.
  final bool debugRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(hostInstallControllerProvider)[host.id];
    // The button's own outcome replaces what the surface was handed: a Retry
    // that failed differently should say the new thing.
    final latest = view?.reading?.deployment;
    final shown =
        latest != null && latest.observedAt.isAfter(deployment.observedAt)
        ? latest
        : deployment;
    final said = explainHostDeployment(
      shown,
      hostName: host.name,
      debugRun: debugRun,
    );
    final busy = view?.busy;

    Future<void> run() async {
      final reading = await ref
          .read(hostInstallControllerProvider.notifier)
          .install(host);
      if (reading != null && reading.deployment == null) onInstalled?.call();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsNotice(
          tone: SettingsNoticeTone.danger,
          message: said.sentence,
          detail: said.remedy.isEmpty ? null : said.remedy,
        ),
        if (said.command case final command?) CopyableCommand(command: command),
        if (said.privileged case final step?)
          PrivilegedCommandBlock(
            host: host,
            step: step,
            busy: busy != null,
            closeDialogFirst: closeDialogFirst,
          ),
        if (view?.failure case final failure?)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: SettingsNotice(
              tone: SettingsNoticeTone.danger,
              message: failure,
            ),
          ),
        if (busy != null)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Row(
              children: [
                const InlineSpinner(),
                const SizedBox(width: Insets.sm),
                Expanded(child: Text(busy.progress)),
              ],
            ),
          )
        else if (said.action != HostDeployAction.none)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: FilledButton.tonal(
              onPressed: run,
              child: Text(said.action.label),
            ),
          ),
      ],
    );
  }
}
