import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_notice.dart';
import '../../ssh/application/ssh_hosts_controller.dart';
import '../application/ssh_relay_controller.dart';
import '../application/ssh_relays.dart';

/// Settings › Remote access: the relays this desktop runs on its own SSH
/// hosts, beside the local and the hosted one. A box with a public address is
/// a meeting place nobody else operates.
class SshRelaysPanel extends ConsumerWidget {
  const SshRelaysPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(sshRelaysProvider);
    final hosts = ref.watch(sshHostsControllerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A Wrap, not a Row with a Spacer: the button goes under the label at
        // the narrowest two-column window with bigger text.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          children: [
            Text(
              'Relays on your SSH hosts',
              style: theme.textTheme.labelMedium,
            ),
            OutlinedButton.icon(
              onPressed: hosts.isEmpty
                  ? null
                  : () => UseSshHostAsRelayDialog.show(context),
              icon: const Icon(AppIcons.plus, size: Chrome.icon),
              label: const Text('Use an SSH host as a relay…'),
            ),
          ],
        ),
        const SizedBox(height: Insets.xs),
        Text(
          hosts.isEmpty
              ? 'Add an SSH host in Settings → Environments first. A machine '
                    'with an address of its own can be the relay phones meet '
                    'this desktop at, with nobody else in between.'
              : entries.isEmpty
              ? 'A machine with an address of its own can be the relay phones '
                    'meet this desktop at, with nobody else in between. It '
                    'forwards sealed frames and can read nothing.'
              : 'Paired phones learn a new relay the next time they connect '
                    'and keep the one they paired through, so nothing has to '
                    'be paired again.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        for (final entry in entries)
          _SshRelayRow(entry: entry, host: _hostFor(entry, hosts)),
      ],
    );
  }

  static SshHost? _hostFor(SshRelayEntry entry, List<SshHost> hosts) {
    for (final host in hosts) {
      if (host.id == entry.hostId) return host;
    }
    return null;
  }
}

class _SshRelayRow extends ConsumerWidget {
  const _SshRelayRow({required this.entry, required this.host});

  final SshRelayEntry entry;

  /// Null once the host was removed from Settings: nothing to connect with, so
  /// the row can only be forgotten.
  final SshHost? host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final view = ref.watch(sshRelayControllerProvider)[entry.hostId];
    final controller = ref.read(sshRelayControllerProvider.notifier);
    final reading = view?.reading;
    final busy = view?.busy ?? false;
    final host = this.host;

    return Padding(
      padding: const EdgeInsets.only(top: Insets.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                AppIcons.terminal,
                size: Chrome.icon,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Insets.sm),
              Expanded(
                child: Text(
                  host?.name ?? entry.hostName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          // The address, never the URL: its path is the access token.
          Text(
            entry.display,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MonoStyles.small,
          ),
          const SizedBox(height: Insets.xs),
          if (busy)
            const Row(
              children: [
                InlineSpinner(),
                SizedBox(width: Insets.sm),
                Expanded(child: Text('Asking the machine…')),
              ],
            )
          else
            _Verdict(entry: entry, view: view, hostGone: host == null),
          if (reading?.command case final command?)
            _CopyableCommand(command: command),
          const SizedBox(height: Insets.xs),
          Wrap(
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              if (host != null) ...[
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => controller.check(host, port: entry.port),
                  icon: const Icon(AppIcons.arrowsClockwise),
                  label: const Text('Check'),
                ),
                if (reading?.status == SshRelayStatus.outdated)
                  FilledButton.tonalIcon(
                    onPressed: busy
                        ? null
                        : () => controller.use(host, port: entry.port),
                    icon: const Icon(AppIcons.arrowsClockwise),
                    label: const Text('Update'),
                  )
                else if (entry.enabled)
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => controller.stop(host, port: entry.port),
                    icon: const Icon(AppIcons.stop),
                    label: const Text('Stop'),
                  )
                else
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => controller.use(host, port: entry.port),
                    icon: const Icon(AppIcons.play),
                    label: const Text('Start'),
                  ),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => _confirmRemove(context, ref, host),
                  icon: const Icon(AppIcons.trash),
                  label: const Text('Remove'),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              ] else
                TextButton.icon(
                  onPressed: () => controller.forget(entry.hostId),
                  icon: const Icon(AppIcons.trash),
                  label: const Text('Forget'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    SshHost host,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove the relay from ${host.name}?'),
        content: BoundedDialogContent(
          width: DialogWidth.narrow,
          child: Text(
            'The relay is stopped and its token, pid and log are deleted on '
            '${host.name}, so its address stops working for good. Phones that '
            'paired through it keep working over any other relay that is on, '
            'and the local network; a phone that knows no other relay has to '
            'be paired again.\n\n'
            'The session host on ${host.name} is left alone.',
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          DestructiveButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(sshRelayControllerProvider.notifier)
        .remove(host, port: entry.port);
  }
}

/// What is known, and how old it is. Before anything was asked this launch it
/// says so rather than repeating what was true last time (§19).
class _Verdict extends ConsumerWidget {
  const _Verdict({
    required this.entry,
    required this.view,
    required this.hostGone,
  });

  final SshRelayEntry entry;
  final SshRelayView? view;
  final bool hostGone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (hostGone) {
      return const SettingsNotice(
        tone: SettingsNoticeTone.attention,
        message:
            'This SSH host was removed from Settings, so its relay can no '
            'longer be checked or stopped from here. If it is still running '
            'on the machine, stop it there.',
      );
    }
    final failure = view?.failure;
    if (failure != null) {
      return SettingsNotice(tone: SettingsNoticeTone.danger, message: failure);
    }
    final reading = view?.reading;
    if (reading == null) {
      return SettingsNotice(
        tone: SettingsNoticeTone.neutral,
        icon: AppIcons.question,
        message: entry.enabled
            ? 'Serving through it. Not checked since this launch — Check '
                  'asks the machine.'
            : 'Not serving through it. Start brings it back; Check asks the '
                  'machine what is there.',
      );
    }
    final age = describeAge(
      ref.read(clockProvider).nowUtc().difference(reading.observedAt.toUtc()),
    );
    final (tone, icon) = switch (reading.status) {
      SshRelayStatus.running => (
        SettingsNoticeTone.positive,
        AppIcons.checkCircle,
      ),
      SshRelayStatus.stopped => (
        SettingsNoticeTone.neutral,
        AppIcons.pauseCircle,
      ),
      SshRelayStatus.outdated => (
        SettingsNoticeTone.attention,
        AppIcons.warningCircle,
      ),
      SshRelayStatus.unknown => (SettingsNoticeTone.neutral, AppIcons.question),
      SshRelayStatus.unreachable || SshRelayStatus.cannotStart => (
        SettingsNoticeTone.danger,
        AppIcons.warningCircle,
      ),
    };
    return SettingsNotice(
      tone: tone,
      icon: icon,
      message: reading.reason,
      detail: 'Checked $age.',
    );
  }
}

/// The line that fixes it, offered to copy rather than to retype.
class _CopyableCommand extends StatelessWidget {
  const _CopyableCommand({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.xs,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(command, style: MonoStyles.small),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Copy command',
            icon: const Icon(AppIcons.copySimple, size: Chrome.icon),
            onPressed: () => Clipboard.setData(ClipboardData(text: command)),
          ),
        ],
      ),
    );
  }
}

/// Picks a box and a port, says what is about to happen there, and does it.
class UseSshHostAsRelayDialog extends ConsumerStatefulWidget {
  const UseSshHostAsRelayDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const UseSshHostAsRelayDialog(),
  );

  @override
  ConsumerState<UseSshHostAsRelayDialog> createState() =>
      _UseSshHostAsRelayDialogState();
}

class _UseSshHostAsRelayDialogState
    extends ConsumerState<UseSshHostAsRelayDialog> {
  final _port = TextEditingController(text: '$kDefaultSshRelayPort');
  String? _hostId;
  String? _portError;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _setUp(SshHost host) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _portError = 'A port is a number from 1 to 65535.');
      return;
    }
    if (port == host.port) {
      setState(() => _portError = 'That is the port SSH itself answers on.');
      return;
    }
    setState(() => _portError = null);
    await ref.read(sshRelayControllerProvider.notifier).use(host, port: port);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hosts = ref.watch(sshHostsControllerProvider);
    final selected =
        hosts.where((host) => host.id == _hostId).firstOrNull ??
        hosts.firstOrNull;
    final view = selected == null
        ? null
        : ref.watch(sshRelayControllerProvider)[selected.id];
    final busy = view?.busy ?? false;
    final reading = view?.reading;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      title: const Text('Use an SSH host as a relay'),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Karmashala puts its session host on the machine if it is not '
              'there yet, starts its relay, and checks from this computer '
              'that it answers. A firewall rule is added only if that check '
              'fails, and the check is made again afterwards.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.md),
            DropdownButtonFormField<String>(
              initialValue: selected?.id,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'SSH host',
              ),
              items: [
                for (final host in hosts)
                  DropdownMenuItem(
                    value: host.id,
                    child: Text(
                      '${host.name} — ${host.host}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() => _hostId = value),
            ),
            const SizedBox(height: Insets.sm),
            SizedBox(
              width: 160,
              child: TextField(
                controller: _port,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: 'Relay port',
                  errorText: _portError,
                  errorMaxLines: 3,
                ),
              ),
            ),
            const SizedBox(height: Insets.md),
            Text(
              'It forwards frames that are sealed between the phone and this '
              'desktop, and can read none of them. It answers only at an '
              'address holding a token the machine makes for itself, so a '
              'stranger who finds the port cannot use it. The connection to it '
              'is not TLS: somebody on the path sees that address, both '
              'ends\' IP addresses, and the size and timing of frames — never '
              'their contents.',
              style: muted,
            ),
            const SizedBox(height: Insets.md),
            if (busy)
              const Row(
                children: [
                  InlineSpinner(size: InlineSpinnerSize.medium),
                  SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      'Setting it up — this connects to the machine…',
                    ),
                  ),
                ],
              )
            else if (view?.failure case final failure?)
              SettingsNotice(tone: SettingsNoticeTone.danger, message: failure)
            else if (reading != null) ...[
              SettingsNotice(
                tone: reading.isServing
                    ? SettingsNoticeTone.positive
                    : SettingsNoticeTone.danger,
                icon: reading.isServing
                    ? AppIcons.checkCircle
                    : AppIcons.warningCircle,
                message: reading.reason,
                detail: reading.isServing
                    ? 'New pairings can choose it, and paired phones learn it '
                          'the next time they connect.'
                    : null,
              ),
              if (reading.command case final command?)
                _CopyableCommand(command: command),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(reading?.isServing ?? false ? 'Done' : 'Cancel'),
        ),
        if (!(reading?.isServing ?? false))
          FilledButton(
            onPressed: busy || selected == null ? null : () => _setUp(selected),
            child: Text(reading == null ? 'Set up' : 'Try again'),
          ),
      ],
    );
  }
}
