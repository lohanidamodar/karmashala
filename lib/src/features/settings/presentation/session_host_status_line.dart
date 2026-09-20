import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: SettingsNotice(
        tone: _toneFor(reading),
        icon: _iconFor(reading),
        message: sessionHostStatusText(reading),
        action: TextButton(
          onPressed: () => ref.read(localHostStatusProvider.notifier).refresh(),
          child: const Text('Check'),
        ),
      ),
    );
  }

  IconData _iconFor(HostDeployment? reading) => switch (reading?.status) {
    null => AppIcons.question,
    HostDeploymentStatus.ready => AppIcons.checkCircle,
    _ => AppIcons.warningCircle,
  };

  SettingsNoticeTone _toneFor(HostDeployment? reading) =>
      switch (reading?.status) {
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
  return switch (reading.status) {
    HostDeploymentStatus.ready =>
      'karmashala_host ${reading.hostVersion ?? 'unknown version'} is running · '
          '$started · checked $age',
    HostDeploymentStatus.unknown =>
      'No session host is running here · checked $age',
    _ => '${reading.reason} · checked $age',
  };
}
