// The session's status-line buttons and opening it in a system terminal.

part of '../session_transcript_view.dart';

/// Stops the process behind a session, wherever it runs: this app's engine,
/// a live terminal pane of ours, or the server's terminal with no pane showing
/// it. It stood in the chat view's header, which is gone (board N2); public so
/// the pane's status line can take it.
///
/// Hidden only when nothing runs the session. It used to ask the engine alone,
/// so a session resumed in a terminal pane — the usual case, Claude Code idle
/// at its prompt — never offered Stop although its process was plainly alive.
class StopSessionButton extends ConsumerWidget {
  const StopSessionButton({required this.sessionId, super.key});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!sessionHasLiveProcess(ref, sessionId)) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Stop session',
      icon: const Icon(AppIcons.stopCircle),
      // The pane's process, else the server's — the same verb the session
      // rows' End uses.
      onPressed: () => endSessionProcess(ref, sessionId),
    );
  }
}

/// The Recap action: asks this session's own CLI what it concluded. Inert
/// while it answers — a second press spends a second turn. It stood in the
/// chat view's header, which is gone; public so the status line can take it.
class SessionRecapButton extends ConsumerWidget {
  const SessionRecapButton({required this.sessionId, super.key});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(sessionRecapRunningProvider(sessionId));
    return IconButton(
      tooltip: running
          ? 'Writing a recap…'
          : 'Recap — ask this session\'s CLI what it concluded',
      icon: running ? const InlineSpinner() : const Icon(AppIcons.article),
      onPressed: running
          ? null
          : () => requestSessionRecap(context, ref, sessionId),
    );
  }
}

/// Opens the session in one of the installed external terminals (Windows
/// Terminal, WezTerm, …), running its agent in the repo. It stood in the chat
/// view's header, which is gone; public so the status line can take it.
class OpenSessionInSystemTerminalButton extends ConsumerWidget {
  const OpenSessionInSystemTerminalButton({required this.sessionId, super.key});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminals = ref.watch(availableSystemTerminalsProvider);
    return terminals.maybeWhen(
      data: (list) => list.isEmpty
          ? const SizedBox.shrink()
          : PopupMenuButton<SystemTerminal>(
              tooltip: 'Open in system terminal',
              icon: const Icon(AppIcons.arrowSquareOut),
              onSelected: (terminal) => openSessionInSystemTerminal(
                context,
                ref,
                sessionId,
                terminal,
              ),
              itemBuilder: (_) => systemTerminalMenuItems(list),
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// One row per installed external terminal, for a menu of where to open.
List<PopupMenuEntry<SystemTerminal>> systemTerminalMenuItems(
  List<SystemTerminal> terminals,
) => [
  for (final t in terminals)
    DesktopMenuItem(
      value: t,
      label: 'Open in ${t.label}',
      icon: AppIcons.terminal,
    ),
];

/// Opens [sessionId] in [terminal], saying so — or why not — in words.
Future<void> openSessionInSystemTerminal(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
  SystemTerminal terminal,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(sessionActionsProvider)
        .openSessionInSystemTerminal(sessionId, terminal);
    messenger.showSnackBar(
      SnackBar(content: Text('Opening in ${terminal.label}…')),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e is StateError ? e.message : '$e')),
    );
  }
}
