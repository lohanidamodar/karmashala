import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_notice.dart';
import '../application/host_install_controller.dart';
import 'copyable_command.dart';
import 'privileged_command_block.dart';

/// "Karmashala host: installed 1.25.0 (running)" and its buttons, for one SSH
/// machine. A reading with its age, taken by Check and after each action —
/// never on its own (§19) — and nothing here needs root.
class HostInstallPanel extends ConsumerWidget {
  const HostInstallPanel({
    required this.host,
    this.compact = false,
    this.debugRun = kDebugMode,
    super.key,
  });

  final SshHost host;

  /// For a row in a list — System health — rather than a card: the line, the
  /// verdict, Check and the one action that moves things on. Stop, Reinstall,
  /// Uninstall and any command to run stay on the machine's card.
  final bool compact;

  /// Whether a missing bundle is answered with the command that builds one.
  final bool debugRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = ref.watch(hostInstallControllerProvider)[host.id];
    final controller = ref.read(hostInstallControllerProvider.notifier);
    final reading = view?.reading;
    final busy = view?.busy;
    final idle = busy == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Karmashala host: '
          '${reading == null ? 'not checked since this launch' : _headline(reading)}',
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: Insets.xs),
        if (!idle)
          Row(
            children: [
              const InlineSpinner(),
              const SizedBox(width: Insets.sm),
              Expanded(child: Text(busy.progress)),
            ],
          )
        else if (view?.failure case final failure?)
          SettingsNotice(tone: SettingsNoticeTone.danger, message: failure)
        else if (reading != null)
          ..._verdict(context, ref, reading, idle: idle),
        const SizedBox(height: Insets.xs),
        Wrap(
          spacing: Insets.xs,
          runSpacing: Insets.xs,
          children: [
            TextButton.icon(
              onPressed: idle ? () => controller.check(host) : null,
              icon: const Icon(AppIcons.arrowsClockwise),
              label: const Text('Check'),
            ),
            if (reading != null) ..._actions(context, ref, reading, idle),
          ],
        ),
      ],
    );
  }

  /// The label, without the reason a `can't install` carries: that is the
  /// notice under it, said once.
  static String _headline(HostInstallReading reading) =>
      switch (reading.state) {
        HostInstallState.cannotInstall => 'can\'t install',
        HostInstallState.unknown => 'unknown',
        _ => reading.label,
      };

  List<Widget> _verdict(
    BuildContext context,
    WidgetRef ref,
    HostInstallReading reading, {
    required bool idle,
  }) {
    final age = describeAge(
      ref.read(clockProvider).nowUtc().difference(reading.observedAt.toUtc()),
    );
    final deployment = reading.deployment;
    if (deployment != null) {
      final said = explainHostDeployment(
        deployment,
        hostName: host.name,
        debugRun: debugRun,
      );
      return [
        SettingsNotice(
          tone: SettingsNoticeTone.danger,
          message: said.sentence,
          detail:
              '${said.remedy}${said.remedy.isEmpty ? '' : ' '}Checked $age.',
        ),
        if (compact && (said.command != null || said.privileged != null))
          Text(
            'The command for it is on ${host.name}\'s card in Settings › '
            'Environments.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else ...[
          if (said.command case final command?)
            CopyableCommand(command: command),
          if (said.privileged case final step?)
            PrivilegedCommandBlock(
              host: host,
              step: step,
              busy: !idle,
              onCheckAgain: () => ref
                  .read(hostInstallControllerProvider.notifier)
                  .install(host),
            ),
        ],
      ];
    }
    final (tone, icon) = switch (reading.state) {
      HostInstallState.installed when reading.running => (
        SettingsNoticeTone.positive,
        AppIcons.checkCircle,
      ),
      HostInstallState.installed => (
        SettingsNoticeTone.neutral,
        AppIcons.pauseCircle,
      ),
      HostInstallState.outdated => (
        SettingsNoticeTone.attention,
        AppIcons.warningCircle,
      ),
      HostInstallState.notInstalled => (
        SettingsNoticeTone.neutral,
        AppIcons.info,
      ),
      HostInstallState.unknown => (
        SettingsNoticeTone.neutral,
        AppIcons.question,
      ),
      HostInstallState.cannotInstall => (
        SettingsNoticeTone.danger,
        AppIcons.warningCircle,
      ),
    };
    return [
      SettingsNotice(
        tone: tone,
        icon: icon,
        message: reading.reason,
        detail: 'Checked $age.',
      ),
    ];
  }

  List<Widget> _actions(
    BuildContext context,
    WidgetRef ref,
    HostInstallReading reading,
    bool idle,
  ) {
    final controller = ref.read(hostInstallControllerProvider.notifier);
    final theme = Theme.of(context);
    final present =
        reading.state == HostInstallState.installed ||
        reading.state == HostInstallState.outdated;
    return [
      if (reading.state == HostInstallState.notInstalled)
        FilledButton.tonalIcon(
          onPressed: idle ? () => controller.install(host) : null,
          icon: const Icon(AppIcons.downloadSimple),
          label: const Text('Install'),
        ),
      if (reading.state == HostInstallState.cannotInstall)
        TextButton.icon(
          onPressed: idle ? () => controller.install(host) : null,
          icon: const Icon(AppIcons.downloadSimple),
          label: const Text('Retry'),
        ),
      if (reading.state == HostInstallState.outdated)
        FilledButton.tonalIcon(
          onPressed: idle ? () => controller.install(host) : null,
          icon: const Icon(AppIcons.downloadSimple),
          // Going back a version is not an update, and is not called one.
          label: Text(
            reading.hostIsNewer
                ? 'Install ${reading.offeredVersion}'
                : 'Update',
          ),
        ),
      if (!compact &&
          reading.state == HostInstallState.installed &&
          reading.canInstall)
        TextButton.icon(
          onPressed: idle ? () => controller.reinstall(host) : null,
          icon: const Icon(AppIcons.downloadSimple),
          label: const Text('Reinstall'),
        ),
      if (!compact && present && reading.running)
        TextButton.icon(
          onPressed: idle ? () => _confirmStop(context, ref, reading) : null,
          icon: const Icon(AppIcons.stop),
          label: const Text('Stop'),
        ),
      if (present && !reading.running)
        TextButton.icon(
          onPressed: idle ? () => controller.start(host) : null,
          icon: const Icon(AppIcons.play),
          label: const Text('Start'),
        ),
      if (!compact && present)
        TextButton.icon(
          onPressed: idle ? () => _confirmRemove(context, ref, reading) : null,
          icon: const Icon(AppIcons.trash),
          // Not "Remove": the card's own Remove forgets the SSH host itself.
          label: const Text('Uninstall'),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
        ),
    ];
  }

  /// A host holding nothing stops without a question; one holding work — or
  /// one that would not say — ends it, so it asks.
  Future<void> _confirmStop(
    BuildContext context,
    WidgetRef ref,
    HostInstallReading reading,
  ) async {
    final held = reading.sessionsHeld;
    if (held != 0) {
      final confirmed = await _confirm(
        context,
        title: 'Stop the session host on ${host.name}?',
        body:
            '${held == null ? 'It would not say how many sessions it holds; any it does' : 'The $held session${held == 1 ? '' : 's'} it holds'} '
            'end with it — shells and agents running there are closed, as if '
            'the machine had restarted. Their recorded output is kept.',
        action: 'Stop',
      );
      if (!confirmed) return;
    }
    await ref.read(hostInstallControllerProvider.notifier).stop(host);
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    HostInstallReading reading,
  ) async {
    final held = reading.sessionsHeld;
    final confirmed = await _confirm(
      context,
      title: 'Uninstall the session host from ${host.name}?',
      body:
          'The session host and the relay on ${host.name} are stopped'
          '${held != null && held > 0 ? ', ending the $held session${held == 1 ? '' : 's'} it holds' : ''}. '
          'Every Karmashala host bundle under ~/.karmashala/bin is deleted, '
          'with the host\'s log and lock and the relay\'s token, pid and log — '
          'so the relay\'s address stops working for good.\n\n'
          'Left in place: ~/.karmashala/sessions (recorded output) and the '
          'store of phones paired with that machine. This SSH host stays in '
          'Karmashala, and the next pane opened there installs the session '
          'host again.',
      action: 'Uninstall',
    );
    if (!confirmed) return;
    await ref.read(hostInstallControllerProvider.notifier).remove(host);
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: BoundedDialogContent(
          width: DialogWidth.narrow,
          child: Text(body),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          DestructiveButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
