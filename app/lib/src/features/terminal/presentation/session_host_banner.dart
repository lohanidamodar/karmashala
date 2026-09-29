import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_runtime/host_link.dart'
    show HostSupervision, HostSupervisionPhase;
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart' show WidthClass;

import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../../core/server/remote_server_access.dart';
import '../../remote/presentation/use_auto_button.dart';
import '../../settings/presentation/session_host_status_line.dart'
    show sessionHostRestartLabel, sessionHostStatusText;
import '../application/local_host_providers.dart';

/// A strip above the shell while this machine's session host needs the person:
/// supervision stopped restarting it on the quick backoff (it only looks again
/// slowly), or an earlier Karmashala's host holds running sessions that only
/// the person may end. Without a host, MCP, hooks, the companion and
/// automations are all gone, and Settings is not where anybody looks first.
///
/// Mounted inside `home`, under the Navigator, so its confirmation can open.
class SessionHostBanner extends ConsumerStatefulWidget {
  const SessionHostBanner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SessionHostBanner> createState() => _SessionHostBannerState();
}

class _SessionHostBannerState extends ConsumerState<SessionHostBanner> {
  /// The supervision the person closed the strip on; it comes back when the
  /// state moves on.
  HostSupervision? _dismissed;
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final supervision = ref.watch(localHostSupervisionProvider).value;
    final shown =
        supervision != null &&
        sessionHostNeedsPerson(supervision) &&
        !_sameNews(supervision, _dismissed);
    // One tree whether or not the strip shows: the shell under it keeps its
    // element, so it is never rebuilt from scratch — which also re-created
    // everything above its content, the macOS menu bar among it.
    final access = ref.watch(serverAccessProvider);
    // The phone shell draws it under its app bar ([RemoteResumingStrip]).
    final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
    return Column(
      children: [
        if (access is RemoteServerAccess && !compact)
          _ResumingStrip(access: access),
        if (shown) _strip(context, supervision),
        Expanded(
          key: const ValueKey('session_host_banner_child'),
          child: widget.child,
        ),
      ],
    );
  }

  Widget _strip(BuildContext context, HostSupervision supervision) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: scheme.onErrorContainer);
    final outdated = supervision.phase == HostSupervisionPhase.outdated;
    return Material(
      key: const ValueKey('session_host_banner'),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(AppIcons.warning, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${outdated ? '' : 'MCP, hooks, the companion and '
                          'automations are off until it runs · '}'
                '${sessionHostStatusText(supervision.reading, supervision: supervision)}',
                style: style,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('session_host_banner_restart'),
              onPressed: _busy ? null : () => _restart(supervision),
              child: Text(
                outdated
                    ? sessionHostRestartLabel(supervision.reading)
                    : 'Restart host',
              ),
            ),
            IconButton(
              key: const ValueKey('session_host_banner_dismiss'),
              icon: Icon(AppIcons.x, color: scheme.onErrorContainer),
              onPressed: () => setState(() => _dismissed = supervision),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _restart(HostSupervision supervision) async {
    final controller = ref.read(localHostStatusProvider.notifier);
    var force = false;
    if (supervision.phase == HostSupervisionPhase.outdated) {
      final held = supervision.heldSessions;
      force = held == null || held.isNotEmpty;
      if (force) {
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
    }
    setState(() => _busy = true);
    try {
      if (supervision.phase == HostSupervisionPhase.outdated) {
        await controller.restart(force: force);
      } else {
        await controller.start();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// "Reconnecting to *server*…" while a remote server's link is held for a
/// resume (Stage 0 step 17), for a phone page to draw under its own app bar.
/// Once the dials give up it stays as "Not connected", with the reason, *Use
/// Auto* while the route is pinned, and *Try again* — unless [whenDown] is
/// false, where the page already says so (the stale session list).
/// Nothing on a local link.
class RemoteResumingStrip extends ConsumerWidget {
  const RemoteResumingStrip({this.whenDown = true, super.key});

  final bool whenDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(serverAccessProvider)) {
        final RemoteServerAccess access => _ResumingStrip(
          access: access,
          linkActions: true,
          whenDown: whenDown,
        ),
        _ => const SizedBox.shrink(),
      };
}

/// The desktop draws it with neither [linkActions] nor [whenDown]: resuming
/// only, nothing to press.
class _ResumingStrip extends ConsumerWidget {
  const _ResumingStrip({
    required this.access,
    this.linkActions = false,
    this.whenDown = false,
  });

  final RemoteServerAccess access;
  final bool linkActions;
  final bool whenDown;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    DataConnection? down;
    if (whenDown) {
      final client = ref.watch(dataClientProvider);
      final connection =
          ref.watch(dataConnectionProvider).value ?? client.connection;
      if (connection.state == DataLinkState.unavailable) down = connection;
    }
    return ValueListenableBuilder<bool>(
      valueListenable: access.resuming,
      builder: (context, resuming, _) {
        if (!resuming && down == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final fore = scheme.onSecondaryContainer;
        final reason = resuming ? null : down?.reason;
        return Material(
          key: const ValueKey('remote_resuming_banner'),
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                if (resuming)
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: fore,
                    ),
                  )
                else
                  Icon(AppIcons.warningCircle, size: 16, color: fore),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        resuming
                            ? 'Reconnecting to ${access.hostName}…'
                            : 'Not connected to ${access.hostName}',
                        style: textTheme.labelMedium?.copyWith(color: fore),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (reason != null)
                        Text(
                          reason,
                          key: const ValueKey('remote_resuming_reason'),
                          style: textTheme.bodySmall?.copyWith(color: fore),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (linkActions) UseAutoButton(foreground: fore),
                if (!resuming)
                  TextButton(
                    key: const ValueKey('remote_resuming_retry'),
                    style: TextButton.styleFrom(foregroundColor: fore),
                    onPressed: ref.read(dataClientProvider).retry,
                    child: const Text('Try again'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Whether [supervision] needs the person: it gave up, or an older host holds
/// sessions (or will not say whether it does).
bool sessionHostNeedsPerson(HostSupervision supervision) =>
    switch (supervision.phase) {
      HostSupervisionPhase.stopped => true,
      HostSupervisionPhase.outdated =>
        supervision.heldSessions?.isNotEmpty ?? true,
      _ => false,
    };

bool _sameNews(HostSupervision a, HostSupervision? b) =>
    b != null && a.phase == b.phase && a.reason == b.reason;
