import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../ssh/domain/host_deployment.dart';
import '../../terminal/application/local_host_providers.dart';
import '../../terminal/presentation/session_status.dart';

/// What the session host on this machine is doing, beside the switch that uses
/// it.
///
/// This is the whole of the supervisor, and saying so is the point. Nothing
/// registers a service or a systemd unit; what exists is that the app starts
/// `serve` when a pane needs one and finds none, and that this line says
/// whether one is running, which version, whether *this* app started it, and
/// **how old that reading is** — so a row that has been on screen for an hour
/// cannot be mistaken for a fresh one.
///
/// It follows §19 exactly: nothing has been checked until something checks, an
/// unknown reads as unknown rather than as "not running", the reading carries
/// its age, and nothing polls — the check runs when the page opens and when the
/// user asks. It also starts nothing: `observe` looks and takes no action, so
/// reading Settings with the switch off cannot launch a daemon.
class SessionHostStatusLine extends ConsumerStatefulWidget {
  const SessionHostStatusLine({super.key});

  @override
  ConsumerState<SessionHostStatusLine> createState() => _SessionHostStatusLineState();
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
    final theme = Theme.of(context);
    final reading = ref.watch(localHostStatusProvider);
    final available = ref.watch(localHostSessionAccessProvider) != null;
    if (!available) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_iconFor(reading), color: _colourFor(reading, theme)),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              sessionHostStatusText(reading),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: Insets.xs),
          TextButton(
            onPressed: () => ref.read(localHostStatusProvider.notifier).refresh(),
            child: const Text('Check'),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(HostDeployment? reading) => switch (reading?.status) {
    null => AppIcons.question,
    HostDeploymentStatus.ready => AppIcons.checkCircle,
    _ => AppIcons.warningCircle,
  };

  Color _colourFor(HostDeployment? reading, ThemeData theme) =>
      switch (reading?.status) {
        HostDeploymentStatus.ready => theme.colorScheme.primary,
        null || HostDeploymentStatus.unknown => theme.colorScheme.onSurfaceVariant,
        _ => theme.colorScheme.error,
      };
}

/// The sentence the row shows, as a pure function so it can be asserted without
/// a widget tree — and so the three facts it must carry stay in one place.
///
/// Never claims health that was not observed: a null [reading] says nothing has
/// been checked, and it is not the same statement as "no host is running".
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
