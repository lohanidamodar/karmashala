import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import '../application/host_sessions.dart';
import '../application/ssh_failure.dart';
import 'host_deploy_failure_notice.dart';

/// **What a machine is still running, and the two things you can do about it.**
///
/// The session host outlives this app on purpose, so a machine can be holding
/// work opened by a Karmashala that has since been closed — and until this
/// existed there was no way to see it, reattach to it, or end it from here.
class HostSessionsDialog extends ConsumerStatefulWidget {
  const HostSessionsDialog({required this.host, super.key});

  final SshHost host;

  static Future<void> show(BuildContext context, {required SshHost host}) =>
      showDialog<void>(
        context: context,
        builder: (_) => HostSessionsDialog(host: host),
      );

  @override
  ConsumerState<HostSessionsDialog> createState() => _HostSessionsDialogState();
}

class _HostSessionsDialogState extends ConsumerState<HostSessionsDialog> {
  /// The tallest the list grows before it scrolls; a dialog also shrinks it to
  /// what the window leaves.
  static const _listMaxHeight = 420.0;

  List<SessionSummary>? _sessions;
  String? _error;

  /// Why there is no host to ask, when that is the failure — shown with its
  /// remedy and an Install button instead of [_error]'s sentence alone.
  HostDeployment? _notDeployed;
  var _busy = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final found = await ref
          .read(hostSessionsServiceProvider)
          .list(widget.host);
      if (mounted) {
        setState(() {
          _sessions = found;
          _error = null;
          _notDeployed = null;
          _busy = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e is HostSessionsUnavailable
              ? e.message
              : describeSshFailure(e);
          _notDeployed = e is HostSessionsUnavailable ? e.deployment : null;
          _busy = false;
        });
      }
    }
  }

  Future<void> _end(SessionSummary session) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(hostSessionsServiceProvider)
          .end(widget.host, session.id);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeSshFailure(e))));
    }
    await _refresh();
  }

  void _attach(SessionSummary session, String paneId) {
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    controller.openTab(
      TerminalProfile.ssh(widget.host.id, hostName: widget.host.name),
      adoptPaneId: paneId,
    );
    controller.showTerminalHere();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _sessions;
    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.terminal,
        title: 'Sessions on ${widget.host.name}',
        subtitle: 'The host keeps these running whether this app is open or not.',
      ),
      content: SizedBox(
        width: DialogWidth.wide,
        child: switch ((_busy, _error, sessions)) {
          (true, _, null) => const Padding(
            padding: EdgeInsets.all(Insets.lg),
            child: Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
          ),
          (false, _, _) when _notDeployed != null => Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: HostDeployFailureNotice(
              host: widget.host,
              deployment: _notDeployed!,
              closeDialogFirst: true,
              onInstalled: _refresh,
            ),
          ),
          (_, final String message, _) => Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(message, style: theme.textTheme.bodyMedium),
          ),
          (_, _, final List<SessionSummary> found) when found.isEmpty => Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(
              'This host is holding nothing.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          (_, _, final List<SessionSummary> found) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _listMaxHeight),
            // Its own traversal group: without one, Tab left the list for the
            // actions part-way down and came back to rows it had visited.
            child: FocusTraversalGroup(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: found.length,
                itemBuilder: (context, i) => _SessionRow(
                  session: found[i],
                  hostId: widget.host.id,
                  onEnd: () => _end(found[i]),
                  onAttach: (paneId) => _attach(found[i], paneId),
                ),
              ),
            ),
          ),
          _ => const SizedBox.shrink(),
        },
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _refresh,
          child: const Text('Refresh'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.hostId,
    required this.onEnd,
    required this.onAttach,
  });

  final SessionSummary session;
  final String hostId;
  final VoidCallback onEnd;
  final void Function(String paneId) onAttach;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = !session.lifecycle.hasEnded;
    final paneId = paneIdOfHostSession(session.id, hostId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: Insets.sm),
            child: Icon(
              running ? AppIcons.playCircle : AppIcons.checkCircle,
              color: running ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.argv.join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  [
                    running ? 'running' : 'ended',
                    if (session.workingDirectory != null)
                      session.workingDirectory!,
                    '${(session.totalBytes / 1024).toStringAsFixed(0)}K of output',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (running && paneId != null)
            TextButton(
              onPressed: () => onAttach(paneId),
              child: const Text('Attach'),
            )
          else if (running)
            // An agent's session is named after the agent, not a pane; it is
            // reopened from the session it belongs to, not from here.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Tooltip(
                message:
                    'This is a Karmashala session, not a bare shell. Resume it '
                    'from the session list to see it again.',
                child: Text(
                  'agent session',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          if (running)
            TextButton(
              onPressed: onEnd,
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              child: const Text('End'),
            ),
        ],
      ),
    );
  }
}
