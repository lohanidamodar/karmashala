import 'dart:io';
import '../../../core/util/failure_words.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show paneIdOfTerminalSession;
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';

import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/host_link.dart';
import '../../sessions/application/session_providers.dart';
import '../../terminal/application/local_host_providers.dart';
import '../data/ssh_client.dart';

/// **What a machine is still running, and the two things you can do about it.**
///
/// The session host outlives this app on purpose, so a machine can be holding
/// work opened by a Karmashala that has since been closed — and until this
/// existed there was no way to see it, reattach to it, or end it from here.
/// A box's are asked of the server, which reaches it (slice 5d).
class HostSessionsDialog extends ConsumerStatefulWidget {
  const HostSessionsDialog({required SshHost this.host, super.key});

  /// The session host on this machine, the one local panes and agents use.
  const HostSessionsDialog.local({super.key}) : host = null;

  /// The machine asked, or null for this one.
  final SshHost? host;

  static Future<void> show(BuildContext context, {required SshHost host}) =>
      showDialog<void>(
        context: context,
        builder: (_) => HostSessionsDialog(host: host),
      );

  static Future<void> showLocal(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const HostSessionsDialog.local(),
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
  var _busy = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final host = widget.host;
      final found = host == null
          ? await _local().listSessions()
          : await ref.read(sshClientProvider).hostSessions(host.id);
      if (mounted) {
        setState(() {
          _sessions = found;
          _error = null;
          _busy = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = switch (e) {
            SocketException() when widget.host == null =>
              'No session host is running on this computer.',
            _ => describeFailure(e),
          };
          _busy = false;
        });
      }
    }
  }

  Future<void> _end(SessionSummary session) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final host = widget.host;
      if (host == null) {
        await _local().endSession(session.id);
      } else {
        await ref.read(sshClientProvider).endHostSession(host.id, session.id);
      }
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeFailure(e))));
    }
    await _refresh();
  }

  LocalHostSessionAccess _local() {
    final access = ref.read(localHostSessionAccessProvider);
    if (access == null) {
      throw const _NoLocalHost();
    }
    return access;
  }

  /// An agent's host session is named `karmashala_<session id>`; a shell's
  /// carries `local_` or a host id instead, and matches no session.
  String? _agentTitleOf(String hostSessionId) {
    const prefix = 'karmashala_';
    const shell = 'karmashala_local_';
    if (!hostSessionId.startsWith(prefix) || hostSessionId.startsWith(shell)) {
      return null;
    }
    final session = ref
        .read(sessionsDataProvider)
        .getById(hostSessionId.substring(prefix.length));
    return session?.title;
  }

  void _attach(SessionSummary session, String paneId) {
    final host = widget.host!;
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    controller.openTab(
      TerminalProfile.ssh(host.id, hostName: host.name),
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
        title: widget.host == null
            ? 'Session host on this computer'
            : 'Sessions on ${widget.host!.name}',
        subtitle:
            'The host keeps these running whether this app is open or not.',
      ),
      content: SizedBox(
        width: DialogWidth.wide,
        child: switch ((_busy, _error, sessions)) {
          (true, _, null) => const Padding(
            padding: EdgeInsets.all(Insets.lg),
            child: Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
          ),
          (_, final String message, _) => Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text(message, style: theme.textTheme.bodyMedium),
          ),
          (_, _, final List<SessionSummary> found) when found.isEmpty =>
            Padding(
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
                  hostId: widget.host?.id,
                  onEnd: () => _end(found[i]),
                  onAttach: (paneId) => _attach(found[i], paneId),
                  agentTitleOf: _agentTitleOf,
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
    required this.agentTitleOf,
  });

  final SessionSummary session;

  /// Null for this computer's host, whose shells are not reattached from here.
  final String? hostId;
  final VoidCallback onEnd;
  final void Function(String paneId) onAttach;

  /// The Karmashala session a host session belongs to, by its title.
  final String? Function(String hostSessionId) agentTitleOf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = !session.lifecycle.hasEnded;
    final paneId = hostId == null ? null : paneIdOfTerminalSession(session.id);
    final agentTitle = agentTitleOf(session.id);
    final isAgent = agentTitle != null || hostId != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xxs, right: Insets.sm),
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
                  agentTitle ?? session.argv.join(' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  [
                    session.lifecycle.describe(),
                    if (agentTitle != null) session.argv.first,
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
          else if (running && isAgent)
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

/// No session host on this computer to ask — drawn as it is, so its
/// `toString` is the sentence.
class _NoLocalHost implements Exception {
  const _NoLocalHost();

  @override
  String toString() => 'This app does not use a session host here.';
}
