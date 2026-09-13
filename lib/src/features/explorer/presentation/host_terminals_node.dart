import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/rows.dart' show compactAge;

import '../../ssh/application/host_sessions.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// **What one machine is still running, in the Explorer, only when asked.**
///
/// The session host outlives this app, so a machine can hold work nobody here
/// opened. Collapsed this costs nothing — no dial, no process. Expanding asks
/// the host once and says how old the answer is; nothing polls (§19).
class HostTerminalsNode extends ConsumerStatefulWidget {
  const HostTerminalsNode({required this.host, super.key});

  final SshHost host;

  @override
  ConsumerState<HostTerminalsNode> createState() => _HostTerminalsNodeState();
}

class _HostTerminalsNodeState extends ConsumerState<HostTerminalsNode> {
  var _open = false;
  var _busy = false;
  List<SessionSummary>? _sessions;
  String? _error;
  DateTime? _readAt;

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final found = await ref
          .read(hostSessionsServiceProvider)
          .list(widget.host);
      if (!mounted) return;
      setState(() {
        _sessions = found;
        _error = null;
        _readAt = DateTime.now();
        _busy = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        // Said in the host's own words: "could not look" is a different
        // answer from "nothing is running", and an empty list would tell the
        // second story for the first reason.
        _error = e is HostSessionsUnavailable ? e.message : '$e';
        _busy = false;
        _readAt = DateTime.now();
      });
    }
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open && _sessions == null && _error == null) _load();
  }

  Future<void> _end(SessionSummary session) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(hostSessionsServiceProvider).end(widget.host, session.id);
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  void _attach(String paneId) {
    final controller = ref.read(terminalSessionsControllerProvider.notifier);
    controller.openTab(
      TerminalProfile.ssh(widget.host.id, hostName: widget.host.name),
      adoptPaneId: paneId,
    );
    controller.showTerminalHere();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sessions = _sessions;
    final running = sessions?.where((s) => !s.lifecycle.hasEnded).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.xs,
            ),
            child: Row(
              children: [
                Icon(
                  _open ? AppIcons.caretDown : AppIcons.caretRight,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Insets.xs),
                Text(
                  'Host terminals',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: Insets.xs),
                if (_busy) ...[
                  const SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: Insets.xs),
                ],
                Expanded(
                  child: Text(
                    _busy
                        ? 'asking ${widget.host.name}…'
                        : _readAt == null
                        ? ''
                        : [
                            if (running != null) '$running running',
                            'read ${compactAge(DateTime.now().difference(_readAt!))} ago',
                          ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (_open)
                  IconButton(
                    tooltip: 'Ask this host again',
                    icon: const Icon(AppIcons.arrowsClockwise),
                    onPressed: _busy ? null : _load,
                  ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          if (_busy && sessions == null && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.md, Insets.xs),
              child: Text(
                // A dial over a network takes as long as it takes; silence
                // here reads as an empty host.
                'Asking this host what it is running…',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (_error case final String message)
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.md, Insets.xs),
              child: Text(
                message,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else if (sessions != null && sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.md, Insets.xs),
              child: Text(
                'This host is holding nothing.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final session in sessions ?? const <SessionSummary>[])
              _HostSessionRow(
                session: session,
                hostId: widget.host.id,
                onEnd: () => _end(session),
                onAttach: _attach,
              ),
        ],
      ],
    );
  }
}

class _HostSessionRow extends StatelessWidget {
  const _HostSessionRow({
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
      padding: const EdgeInsets.fromLTRB(Insets.lg, 0, Insets.sm, 2),
      child: Row(
        children: [
          Icon(
            running ? AppIcons.playCircle : AppIcons.checkCircle,
            color: running ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              session.argv.join(' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall,
            ),
          ),
          if (running && paneId != null)
            TextButton(
              onPressed: () => onAttach(paneId),
              child: const Text('Attach'),
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
