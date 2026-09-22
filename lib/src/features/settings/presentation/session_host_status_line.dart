import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ssh/host.dart';
import '../../terminal/application/local_host_providers.dart';
import '../../terminal/presentation/session_status.dart';
import 'settings_notice.dart';

/// What the session host on this machine is doing, beside the switch that uses
/// it. Per §19 the reading carries its age and nothing polls; `observe` starts
/// nothing, so reading Settings with the switch off cannot launch a daemon.
class SessionHostStatusLine extends ConsumerStatefulWidget {
  const SessionHostStatusLine({super.key});

  @override
  ConsumerState<SessionHostStatusLine> createState() =>
      _SessionHostStatusLineState();
}

class _SessionHostStatusLineState extends ConsumerState<SessionHostStatusLine> {
  @override
  void initState() {
    super.initState();
    // When the panel opens, and never on a timer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(localHostStatusProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reading = ref.watch(localHostStatusProvider);
    final available = ref.watch(localHostSessionAccessProvider) != null;
    if (!available) return const SizedBox.shrink();

    final check = TextButton(
      onPressed: () => ref.read(localHostStatusProvider.notifier).refresh(),
      child: const Text('Check'),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: SettingsNotice(
        tone: _toneFor(reading),
        icon: _iconFor(reading),
        message: sessionHostStatusText(reading),
        action: reading?.hostOutdated ?? false
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    key: const ValueKey('session-host-restart'),
                    onPressed: () => _restart(reading!),
                    child: const Text('Restart'),
                  ),
                  check,
                ],
              )
            : check,
      ),
    );
  }

  /// Ends what the old host holds only when the person says so, by name.
  Future<void> _restart(HostDeployment reading) async {
    final held = reading.liveSessionIds;
    final holdsSome = held == null || held.isNotEmpty;
    if (holdsSome) {
      final confirmed = await showConfirmDialog(
        context,
        title: 'Restart the session host?',
        message: held == null
            ? 'The running host would not say what it holds. Restarting it '
                  'ends every session it is running.'
            : 'This ends the ${held.length} session(s) it is running. Their '
                  'panes keep what they showed, but the processes stop.',
        confirmLabel: 'Restart',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    await ref.read(localHostStatusProvider.notifier).restart(force: holdsSome);
  }

  IconData _iconFor(HostDeployment? reading) => switch (reading?.status) {
    null => AppIcons.question,
    HostDeploymentStatus.ready when reading!.hostOutdated =>
      AppIcons.warningCircle,
    HostDeploymentStatus.ready => AppIcons.checkCircle,
    _ => AppIcons.warningCircle,
  };

  SettingsNoticeTone _toneFor(HostDeployment? reading) =>
      switch (reading?.status) {
        HostDeploymentStatus.ready when reading!.hostOutdated =>
          SettingsNoticeTone.attention,
        HostDeploymentStatus.ready => SettingsNoticeTone.positive,
        null || HostDeploymentStatus.unknown => SettingsNoticeTone.neutral,
        _ => SettingsNoticeTone.danger,
      };
}

/// The sentence the row shows, as a pure function so it can be asserted without
/// a widget tree. A null [reading] says nothing has been checked, which is not
/// the same statement as "no host is running".
String sessionHostStatusText(HostDeployment? reading, {DateTime? now}) {
  if (reading == null) return 'Nothing has been checked yet.';
  final age = describeAge(reading.observedAt.toUtc(), now: now?.toUtc());
  final started = reading.restartedByUs
      ? 'started by this app'
      : 'not started by this app';
  if (reading.isReady && reading.hostOutdated) {
    final held = reading.liveSessionIds;
    final holds = held == null
        ? 'it would not say how many sessions it holds'
        : 'it holds ${held.length} running session(s)';
    return 'An older session host, left by an earlier Karmashala, is running · '
        '$holds, which keep working · new terminals run inside the app until '
        'it is restarted · checked $age';
  }
  return switch (reading.status) {
    HostDeploymentStatus.ready =>
      'karmashala_host ${reading.hostVersion ?? 'unknown version'} is running · '
          '$started · checked $age',
    HostDeploymentStatus.unknown =>
      'No session host is running here · checked $age',
    _ => '${reading.reason} · checked $age',
  };
}
