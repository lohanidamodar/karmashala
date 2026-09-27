import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_host_protocol/host_access.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase;
import '../../ssh/presentation/host_sessions_dialog.dart';
import '../../terminal/application/local_host_providers.dart';
import '../../terminal/presentation/session_status.dart';
import 'settings_notice.dart';

/// What the session host on this machine is doing, beside the switch that uses
/// it. Per §19 the reading carries its age and the row itself polls nothing;
/// `observe` starts nothing, so reading Settings with the switch off cannot
/// launch a daemon. While the app supervises the host, its state — restarting,
/// or stopped and why — is what the row says.
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
    final supervision = ref.watch(localHostSupervisionProvider).value;
    final available = ref.watch(localHostSessionAccessProvider) != null;
    if (!available) return const SizedBox.shrink();

    final check = TextButton(
      onPressed: () => ref.read(localHostStatusProvider.notifier).refresh(),
      child: const Text('Check'),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      child: SettingsNotice(
        tone: _toneFor(reading, supervision),
        icon: _iconFor(reading, supervision),
        message: sessionHostStatusText(reading, supervision: supervision),
        action: _actionsFor(reading, supervision, check),
      ),
    );
  }

  Widget _actionsFor(
    HostDeployment? reading,
    HostSupervision? supervision,
    Widget check,
  ) {
    final restart = TextButton(
      key: const ValueKey('session-host-restart'),
      onPressed: () => _restart(reading!),
      child: Text(sessionHostRestartLabel(reading)),
    );
    Widget row(List<Widget> children) =>
        Row(mainAxisSize: MainAxisSize.min, children: [...children, check]);
    // Supervision gave up, or is between attempts: the person may start it now.
    final phase = supervision?.phase;
    if (phase == HostSupervisionPhase.stopped ||
        phase == HostSupervisionPhase.restarting) {
      return row([
        TextButton(
          key: const ValueKey('session-host-start'),
          onPressed: () => ref.read(localHostStatusProvider.notifier).start(),
          child: Text(
            phase == HostSupervisionPhase.stopped ? 'Restart' : 'Restart now',
          ),
        ),
      ]);
    }
    // An earlier Karmashala's host, kept for the sessions it runs: ending
    // them is the person's call, and the button says so.
    if (reading?.hostOutdated ?? false) return row([restart]);
    // Offered whenever a host answers: a current one can need a restart too —
    // a new build installed beside it, or a host gone wrong.
    if (reading?.isReady ?? false) {
      return row([
        TextButton(
          key: const ValueKey('session-host-sessions'),
          onPressed: () => HostSessionsDialog.showLocal(context),
          child: const Text('Sessions'),
        ),
        restart,
      ]);
    }
    // One that holds the socket and will not answer is the host gone wrong,
    // and restarting it is the only way past it.
    if (reading?.hostUnresponsive ?? false) return row([restart]);
    if (reading?.status == HostDeploymentStatus.unknown) {
      return row([
        TextButton(
          key: const ValueKey('session-host-start'),
          onPressed: () => ref.read(localHostStatusProvider.notifier).start(),
          child: const Text('Start'),
        ),
      ]);
    }
    return check;
  }

  /// Ends what the old host holds only when the person says so, by name.
  Future<void> _restart(HostDeployment reading) async {
    // A host that will not answer the handshake will not list either, so it
    // is not asked again.
    final held = reading.hostUnresponsive
        ? null
        : reading.liveSessionIds ??
              await ref.read(localHostSessionAccessProvider)?.liveSessionIds();
    if (!mounted) return;
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

  IconData _iconFor(HostDeployment? reading, HostSupervision? supervision) =>
      switch (reading?.status) {
        _ when supervision?.phase == HostSupervisionPhase.stopped =>
          AppIcons.warningCircle,
        _ when supervision?.phase == HostSupervisionPhase.restarting =>
          AppIcons.warningCircle,
        null => AppIcons.question,
        _ when reading!.hostOutdated => AppIcons.warningCircle,
        HostDeploymentStatus.ready => AppIcons.checkCircle,
        _ when reading.hostUnresponsive => AppIcons.warningCircle,
        HostDeploymentStatus.unknown => AppIcons.question,
        _ => AppIcons.warningCircle,
      };

  SettingsNoticeTone _toneFor(
    HostDeployment? reading,
    HostSupervision? supervision,
  ) => switch (reading?.status) {
    _ when supervision?.phase == HostSupervisionPhase.stopped =>
      SettingsNoticeTone.danger,
    _ when supervision?.phase == HostSupervisionPhase.restarting =>
      SettingsNoticeTone.attention,
    _ when reading?.hostOutdated ?? false => SettingsNoticeTone.attention,
    HostDeploymentStatus.ready => SettingsNoticeTone.positive,
    null => SettingsNoticeTone.neutral,
    _ when reading!.hostUnresponsive => SettingsNoticeTone.attention,
    HostDeploymentStatus.unknown => SettingsNoticeTone.neutral,
    _ => SettingsNoticeTone.danger,
  };
}

/// What the restart button says: an older host's sessions end with it, and the
/// button names how many before anything is pressed.
String sessionHostRestartLabel(HostDeployment? reading) {
  if (!(reading?.hostOutdated ?? false)) return 'Restart';
  final held = reading!.liveSessionIds;
  if (held == null) return 'Restart host (ends its sessions)';
  if (held.isEmpty) return 'Restart host';
  return 'Restart host (ends ${held.length} '
      '${held.length == 1 ? 'session' : 'sessions'})';
}

/// The sentence the row shows, as a pure function so it can be asserted without
/// a widget tree. A null [reading] says nothing has been checked, which is not
/// the same statement as "no host is running". A [supervision] that is
/// restarting or has stopped speaks first: that is what the host is doing.
String sessionHostStatusText(
  HostDeployment? reading, {
  DateTime? now,
  HostSupervision? supervision,
}) {
  final supervised = _supervisionText(supervision, now: now);
  if (supervised != null) return supervised;
  if (reading == null) return 'Nothing has been checked yet.';
  final age = describeAge(reading.observedAt.toUtc(), now: now?.toUtc());
  final started = reading.restartedByUs
      ? 'started by this app'
      : 'not started by this app';
  if (reading.hostOutdated &&
      reading.status == HostDeploymentStatus.protocolMismatch) {
    final held = reading.liveSessionIds;
    final holds = held == null
        ? 'its session records could not be read, so it may be running some'
        : 'it holds ${held.length} running session(s)';
    return 'A session host from an earlier Karmashala, speaking another '
        'protocol, is running · $holds, so it is left running until you '
        'restart it · new terminals run inside the app · checked $age';
  }
  if (reading.isReady && reading.hostOutdated) {
    final held = reading.liveSessionIds;
    final holds = held == null
        ? 'it would not say how many sessions it holds'
        : 'it holds ${held.length} running session(s)';
    return 'An older session host, left by an earlier Karmashala, is running · '
        '$holds, which keep working · new terminals run inside the app until '
        'it is restarted · checked $age';
  }
  if (reading.hostUnresponsive) {
    return 'A session host holds the socket here but did not answer · it may '
        'be busy or stuck, and no second one is started over it · checked $age';
  }
  return switch (reading.status) {
    HostDeploymentStatus.ready =>
      'karmashala_host ${reading.hostVersion ?? 'unknown version'} is running'
          '${reading.hostPid == null ? '' : ' (pid ${reading.hostPid})'} · '
          '$started · checked $age',
    HostDeploymentStatus.unknown =>
      'No session host is running here · checked $age',
    _ => '${reading.reason} · checked $age',
  };
}

/// What supervision says when it is the news: restarting, or stopped and why,
/// with the host's last lines when this app started it. Null otherwise.
String? _supervisionText(HostSupervision? supervision, {DateTime? now}) {
  if (supervision == null) return null;
  final output = supervision.lastOutput;
  final tail = output.isEmpty
      ? ''
      : ' · its last output: ${output.skip(output.length > 5 ? output.length - 5 : 0).join(' ⏎ ')}';
  switch (supervision.phase) {
    case HostSupervisionPhase.restarting:
      final next = supervision.nextAttemptAt;
      final wait = next == null
          ? ''
          : ', next in ${_seconds(next.difference(now ?? DateTime.now()))}';
      final why = supervision.reason;
      return 'Session host: restarting… · attempt ${supervision.attempt} of '
          '${supervision.maxAttempts}$wait'
          '${why == null || why.isEmpty ? '' : ' · $why'}$tail';
    case HostSupervisionPhase.stopped:
      final next = supervision.nextAttemptAt;
      final look = next == null
          ? ''
          : ' · looked at again in '
                '${_seconds(next.difference(now ?? DateTime.now()))}';
      return 'Session host: stopped: ${supervision.reason ?? 'no reason was '
              'recorded'}$look$tail';
    case HostSupervisionPhase.idle:
    case HostSupervisionPhase.starting:
    case HostSupervisionPhase.running:
    case HostSupervisionPhase.outdated:
      return null;
  }
}

String _seconds(Duration duration) {
  final seconds = (duration.inMilliseconds / 1000).ceil();
  return '${seconds < 0 ? 0 : seconds}s';
}
