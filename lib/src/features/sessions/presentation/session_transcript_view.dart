import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/shell/side_panel_state.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/read.dart';
import '../../cli_detection/presentation/subagent_turns_tile.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../file_explorer/application/file_explorer_providers.dart';
import '../../notes/application/composer_draft.dart';
import '../../notes/application/notes_providers.dart';
import '../../repositories/application/repository_providers.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../../terminal/data/system_terminal_service.dart';
import '../application/session_actions.dart';
import '../application/session_chat_source.dart';
import '../application/session_chat_view_providers.dart';
import '../application/session_engine_provider.dart';
import '../application/session_providers.dart';
import '../application/session_ui_providers.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'activity_strip.dart';
import 'agent_status_badge.dart';
import 'approval_request_card.dart';
import 'chat_transcript.dart';
import 'session_recap_card.dart';
import 'delivery_strip.dart';
import 'message_composer.dart';
import 'permission_mode_chip.dart';
import 'model_chip.dart';
import 'session_notice_line.dart';
import 'session_repositories_bar.dart';
import 'session_stats_dialog.dart';

/// The chat transcript for the selected native session, rendered CLI-style. Only
/// conversational events are shown — lifecycle/status noise is filtered out.
class SessionTranscriptView extends ConsumerStatefulWidget {
  const SessionTranscriptView({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<SessionTranscriptView> createState() =>
      _SessionTranscriptViewState();
}

class _SessionTranscriptViewState extends ConsumerState<SessionTranscriptView> {
  /// The most of the footer the composer may take; the strips get the rest.
  static const _composerShare = 0.7;

  /// The most of the conversation's height the recap may take.
  static const _recapShare = 0.3;

  /// Owned here rather than inside the composer, because something outside the
  /// composer writes to it: a note sent back lands in this box.
  final _composer = TextEditingController();

  /// Which delegated agent hangs under which row, by the row's index in the
  /// whole transcript. Read back by [ChatTranscriptView.detailBuilder].
  final _subagents = <int, SubagentRef>{};

  /// Held rather than read in [dispose]: `ref` is unusable once the element is
  /// on its way out, and the draft has to be parked exactly then.
  late final ComposerDrafts _drafts;

  /// Set before the draft is parked, because parking it notifies this widget's
  /// own listener on the same provider and `ref` is dead by then.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(composerDraftProvider.notifier);
  }

  @override
  void dispose() {
    // The workbench unmounts the conversation when it moves to another session,
    // so half-typed text is parked where the next mount already looks for it.
    _leaving = true;
    final draft = _composer.text;
    if (draft.trim().isNotEmpty) _drafts.queue(widget.sessionId, draft);
    _composer.dispose();
    super.dispose();
  }

  /// Moves whatever the Notes panel queued for this session into the box.
  /// Appended, not assigned, and never sent — the user reads it first.
  void _takeQueuedNote() {
    if (_leaving) return;
    final queued = _drafts.take(widget.sessionId);
    if (queued == null || queued.isEmpty) return;
    final existing = _composer.text.trimRight();
    _composer.text = existing.isEmpty ? queued : '$existing\n\n$queued';
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
  }

  /// Keeps [message] as a note, word for word, remembering where it was taken
  /// from. One tap: no dialog, no title, nothing rewritten.
  void _saveNote(ChatMessage message, int ordinal) {
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    ref
        .read(notesProvider.notifier)
        .capture(
          body: message.text,
          sourceSessionId: widget.sessionId,
          sourceRepositoryId: session?.repositoryId,
          sourceMessageOrdinal: ordinal,
          sourceMessageRole: message.role,
        );
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Saved to Notes.')));
  }

  /// Translates a path the agent wrote into one this process can open, or null
  /// when the environment is unknown: a WSL `/mnt/c/…` has to become `C:\…`.
  String? Function(String)? _hostPathResolver() {
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    if (session == null) return null;
    final environmentId = ref
        .read(agentInstallationDaoProvider)
        .getById(session.agentInstallationId)
        ?.environmentId;
    if (environmentId == null) return null;
    final editor = ref.read(editorActionsProvider);
    return (path) => editor.windowsPathFor(
      EnvironmentPath(environmentId: environmentId, path: path),
    );
  }

  /// Where this session's agent was standing. Null means **unknown**, never
  /// "the repository root", so the fallback is made here and out loud.
  EnvironmentPath? _workingDirectory() {
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    if (session == null) return null;
    return session.workingDirectory ??
        ref.read(repositoryDaoProvider).getById(session.repositoryId)?.path;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// What a click on a file path does: **it reveals; it does not open**. Also
  /// the only place the feature touches a disk — detection is by shape.
  Future<void> _openPath(String token) async {
    final parsed = tokenForMatch(token);
    final base = _workingDirectory();
    if (base == null) {
      _say(
        'Karmashala has no record of where this session runs, so it '
        'cannot place ${parsed.path}.',
      );
      return;
    }
    final kind = ref
        .read(executionEnvironmentDaoProvider)
        .getById(base.environmentId)
        ?.kind;
    final resolved = resolveTranscriptPath(
      parsed.path,
      workingDirectory: base.path,
      context: transcriptPathContext(kind),
    );
    final path = EnvironmentPath(
      environmentId: base.environmentId,
      path: resolved,
    );

    // No host spelling: an SSH session's files are on the other machine, and
    // `RevealInFileManager` is the one place that words that.
    final revealer = ref.read(revealInFileManagerProvider);
    final hostPath = ref.read(editorActionsProvider).windowsPathFor(path);
    if (hostPath == null) {
      _say(
        (await revealer.reveal(path)).error ??
            'There is no path on this '
                'machine for $resolved.',
      );
      return;
    }

    final type = ref.read(hostPathProbeProvider)(hostPath);
    if (type == FileSystemEntityType.notFound) {
      _say('$resolved is not on disk.');
      return;
    }
    final isDirectory = type == FileSystemEntityType.directory;

    // Inside the checkout the panel is rooted at: show it there, where the
    // reader already is.
    final root = ref.read(selectedRepoWindowsRootProvider);
    if (root != null && isUnderFileTreeRoot(root, hostPath)) {
      ref
          .read(fileRevealTargetProvider.notifier)
          .reveal(
            FileRevealTarget(hostPath: hostPath, isDirectory: isDirectory),
          );
      if (ref.read(sidePanelProvider) != SidePanelSurface.files) {
        ref.read(sidePanelProvider.notifier).select(SidePanelSurface.files);
      }
      return;
    }

    // Outside it there is no row to select, so the host's own file manager is
    // all that is left. `canReveal` starts no process, so asking first is free.
    if (!revealer.canReveal(path)) {
      _say(
        (await revealer.reveal(path)).error ??
            'There is no way to show '
                '$resolved on this machine.',
      );
      return;
    }
    final outcome = await revealer.reveal(path, select: !isDirectory);
    if (!outcome.ok) _say(outcome.error!);
  }

  Future<void> _stop() async {
    await ref.read(sessionEngineProvider).stop(widget.sessionId);
    ref.publishSessionChange(SessionChange.statusChanged(widget.sessionId));
  }

  @override
  Widget build(BuildContext context) {
    // Only this session's row. The transcript of one conversation says nothing
    // about any other, and used to redraw whenever any of them moved.
    ref.watchSession(widget.sessionId);
    final notesEnabled = ref.watch(notesEnabledProvider);
    // A note sent back while this session was not on screen is waiting rather
    // than lost; pick it up as soon as the box exists to hold it.
    ref.listen(composerDraftProvider, (_, next) {
      if (next.containsKey(widget.sessionId)) _takeQueuedNote();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _takeQueuedNote();
    });
    final session = ref.read(sessionDaoProvider).getById(widget.sessionId);
    // A PTY-hosted session's conversation lives in the agent's own transcript
    // (see `SessionTranscriptLocator`): stdout carries no structured stream.
    final fromPty = session?.surface == SessionSurface.pane;
    final transcript = fromPty
        ? ref
              .watch(sessionChatTranscriptProvider(widget.sessionId))
              .whenData(_fromTranscript)
        : ref
              .watch(sessionTranscriptProvider(widget.sessionId))
              .whenData(_toMessages);
    final resolveHostPath = _hostPathResolver();
    final active =
        fromPty || ref.read(sessionEngineProvider).isActive(widget.sessionId);
    // Whether a chat rendering is possible for **this session** — a reading,
    // not a registry lookup; `reading.reason` says which nothing it is.
    final reading = fromPty
        ? sessionChatView(ref, widget.sessionId)
        : const SessionChatView.unread(prior: true);
    final chatAvailable = !fromPty || reading.hasChatView;
    // Whether there is a terminal to point at. Nothing lands a session here on
    // its own any more, but the user can switch, so the sentences must be true.
    final hasTerminal = sessionTerminalPane(ref, widget.sessionId) != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // No title and no back button: the workbench tab above already names
        // and closes the session, and the strip's toggle switches the view.
        SizedBox(
          // Grows with the text: the badge's label follows the text scale.
          height: Chrome.tabStripOf(context),
          child: Row(
            children: [
              const SizedBox(width: Insets.md),
              AgentStatusBadge(sessionId: widget.sessionId, showLabel: true),
              const Spacer(),
              // On the header rather than in the composer's chip row: a recap
              // costs a turn, so it sits with the other deliberate acts.
              _RecapButton(sessionId: widget.sessionId),
              _OpenInTerminalButton(sessionId: widget.sessionId),
              if (active)
                IconButton(
                  tooltip: 'Stop session',
                  icon: const Icon(AppIcons.stopCircle),
                  onPressed: _stop,
                ),
              const SizedBox(width: Insets.xs),
            ],
          ),
        ),
        SessionRepositoriesBar(sessionId: widget.sessionId),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Above the messages and outside their scroll: a digest you
                // have to scroll back to is of a conversation already re-read.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: box.maxHeight * _recapShare,
                  ),
                  child: SessionRecapCard(sessionId: widget.sessionId),
                ),
                Expanded(
                  child: _conversation(
                    transcript: transcript,
                    resolveHostPath: resolveHostPath,
                    notesEnabled: notesEnabled,
                    active: active,
                    chatAvailable: chatAvailable,
                    reading: reading,
                    fromPty: fromPty,
                    hasTerminal: hasTerminal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _conversation({
    required AsyncValue<List<ChatMessage>> transcript,
    required String? Function(String)? resolveHostPath,
    required bool notesEnabled,
    required bool active,
    required bool chatAvailable,
    required SessionChatView reading,
    required bool fromPty,
    required bool hasTerminal,
  }) {
    return transcript.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (messages) => ChatTranscriptView(
        messages: messages,
        resolveHostPath: resolveHostPath,
        // Paths in the conversation are clickable, and a click reveals
        // rather than opens — see [_openPath].
        onPathTap: _openPath,
        // What the parent's `Task(…)` row never showed. Collapsed and
        // unread until opened — one session's turns came to 1,485 MiB.
        detailBuilder: (message, ordinal) {
          final reference = _subagents[ordinal];
          if (reference == null) return null;
          return SubagentTurnsTile(
            reference: reference,
            resolveHostPath: resolveHostPath,
          );
        },
        // Null when Notes is off: the transcript never learns the
        // feature exists, so there is nothing left behind to hide.
        onSaveNote: notesEnabled ? _saveNote : null,
        // The delivery strip sits on the composer's channel: its prompt
        // actions send through `continueSession`.
        footer: LayoutBuilder(
          builder: (context, box) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The strips scroll among themselves in whatever the
              // composer leaves; none of them may push the box away.
              Flexible(
                child: SingleChildScrollView(
                  primary: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Above the handoff row and the composer, because
                      // it blocks the session: nothing typed is read
                      // until it is answered.
                      ApprovalRequestCard(sessionId: widget.sessionId),
                      DeliveryStrip(sessionId: widget.sessionId),
                      // Directly above the box: "what is it doing right
                      // now" was only answerable by scrolling to the end.
                      ActivityStrip(sessionId: widget.sessionId),
                      // Directly above the composer whose chip row posts
                      // it, so the answer sits next to the chip.
                      SessionNoticeLine(sessionId: widget.sessionId),
                    ],
                  ),
                ),
              ),
              ConstrainedBox(
                // A long draft may not crowd an approval out of sight.
                constraints: BoxConstraints(
                  maxHeight: box.maxHeight * _composerShare,
                ),
                child: MessageComposer(
                  controller: _composer,
                  // MonoCode's chip row: the session's own safety policy,
                  // and what it has cost, beside the session itself.
                  chips: [
                    PermissionModeChip(sessionId: widget.sessionId),
                    // The same pair as the terminal's own bar, in the
                    // same order: what it may do without asking, and
                    // what with.
                    SessionModelChip(sessionId: widget.sessionId),
                    SessionStatsButton(sessionId: widget.sessionId),
                  ],
                  hintText: active
                      // No emoji: the old hint named a 🖼 that is nowhere
                      // in the composer; the attach tooltip does.
                      ? 'Message the agent…'
                      : 'Type to continue this session…',
                  onSend: (text) => ref
                      .read(sessionActionsProvider)
                      .continueSession(widget.sessionId, text),
                ),
              ),
            ],
          ),
        ),
        emptyHint: _emptyHint(
          chatAvailable: chatAvailable,
          reading: reading,
          fromPty: fromPty,
          active: active,
          hasTerminal: hasTerminal,
        ),
      ),
    );
  }

  /// What to say when there is nothing to render. Each branch reads the same
  /// `sessionTerminalPane` the workbench does, so the two cannot disagree.
  String _emptyHint({
    required bool chatAvailable,
    required SessionChatView reading,
    required bool fromPty,
    required bool active,
    required bool hasTerminal,
  }) {
    if (!chatAvailable) {
      // The refusal names *why* it is one: "keeps no transcript" was true of
      // every Antigravity session until one install turned out to keep them.
      return hasTerminal
          ? 'No chat view for this session. ${reading.reason} Its terminal is '
                'the session.'
          : 'No chat view for this session. ${reading.reason} This session has '
                'no terminal open either, so there is nothing to show. '
                'Type below to run it again.';
    }
    if (fromPty) {
      return hasTerminal
          ? 'Nothing in this session\'s transcript yet — it appears once the '
                'agent answers. The terminal shows it live.'
          : 'Nothing in this session\'s transcript yet — it appears once the '
                'agent answers.';
    }
    return active
        ? 'Session is running — say something to the agent.'
        : 'No messages yet.';
  }

  /// The agent's own transcript as chat messages. The subagent a row spawned
  /// travels beside them, not inside [ChatMessage], which has no room for it.
  List<ChatMessage> _fromTranscript(List<TranscriptMessage> messages) {
    _subagents.clear();
    return chatMessagesFromTranscript(messages, subagents: _subagents);
  }

  /// Maps the persisted event log to displayable chat messages, dropping
  /// lifecycle/status noise (verbose logs are not shown in the chat).
  List<ChatMessage> _toMessages(List<SessionEvent> events) {
    final messages = <ChatMessage>[];
    for (final event in events) {
      switch (event.type) {
        case SessionEventTypes.userMessage:
          _addText(messages, 'user', event.payload);
        case SessionEventTypes.agentMessage:
          _addText(messages, 'agent', event.payload);
        case SessionEventTypes.error:
          _addText(messages, 'error', event.payload);
        case SessionEventTypes.sessionFailed:
          messages.add(
            const ChatMessage(role: 'error', text: 'Session failed.'),
          );
        case SessionEventTypes.toolCall:
          _addToolCall(messages, event.payload);
        case SessionEventTypes.sessionCancelled:
          messages.add(const ChatMessage(role: 'tool', text: 'Session ended.'));
      }
    }
    return messages;
  }

  /// A tool call from the engine's own event log. It cannot yet show what came
  /// back: `SessionEventTypes.toolResult` is named and nothing emits it.
  void _addToolCall(List<ChatMessage> out, String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return;
      final name = decoded['name'];
      if (name is! String || name.isEmpty) return;
      final activity = toolActivityFor(name, decoded['input']);
      out.add(
        ChatMessage(role: 'tool', text: activity.summary, tool: activity),
      );
    } on FormatException {
      // not JSON
    }
  }

  void _addText(List<ChatMessage> out, String role, String payload) {
    final text = _text(payload);
    if (text.isNotEmpty) out.add(ChatMessage(role: role, text: text));
  }

  String _text(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return (decoded['text'] ?? '').toString();
      }
    } on FormatException {
      // not JSON
    }
    return '';
  }
}

/// The header's Recap action: asks this session's own CLI what it concluded.
/// Inert while it answers — a second press spends a second turn.
class _RecapButton extends ConsumerWidget {
  const _RecapButton({required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(sessionRecapRunningProvider(sessionId));
    return IconButton(
      tooltip: running
          ? 'Writing a recap…'
          : 'Recap — ask this session\'s CLI what it concluded',
      icon: running
          ? const SizedBox(
              width: Chrome.iconSmall,
              height: Chrome.iconSmall,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(AppIcons.article),
      onPressed: running
          ? null
          : () => requestSessionRecap(context, ref, sessionId),
    );
  }
}

/// A header action that opens the session in one of the installed external
/// terminals (Windows Terminal, WezTerm, …), running its agent in the repo.
class _OpenInTerminalButton extends ConsumerWidget {
  const _OpenInTerminalButton({required this.sessionId});
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
              onSelected: (terminal) async {
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
              },
              itemBuilder: (context) => [
                for (final t in list)
                  DesktopMenuItem(
                    value: t,
                    label: 'Open in ${t.label}',
                    icon: AppIcons.terminal,
                  ),
              ],
            ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// The pane [sessionId] can be *shown* in, or null when it has none. A row
/// keeps its `pane_id` after the pane is gone, so an instance must still exist.
String? sessionTerminalPane(WidgetRef ref, String sessionId) {
  final paneId = ref.read(sessionDaoProvider).getById(sessionId)?.paneId;
  if (paneId == null) return null;
  final terminals = ref.read(terminalSessionsControllerProvider.notifier);
  return terminals.instanceFor(paneId) == null ? null : paneId;
}

/// A CLI transcript as chat messages, with a compacted session's history shown
/// **once** — the summary restates everything before the last boundary.
@visibleForTesting
List<ChatMessage> chatMessagesFromTranscript(
  List<TranscriptMessage> messages, {
  Map<int, SubagentRef>? subagents,
}) {
  // The **last** boundary: a session compacted twice has restated its history
  // twice, and only the newest summary covers all of it.
  var from = 0;
  CompactionBoundary? boundary;
  for (var i = messages.length - 1; i > 0; i--) {
    final compaction = messages[i].compaction;
    if (compaction != null) {
      from = i;
      boundary = compaction;
      break;
    }
  }

  final out = <ChatMessage>[];
  if (boundary != null) {
    final trigger = boundary.trigger;
    out.add(
      ChatMessage(
        role: kCompactionNoticeRole,
        // The count, because a reader must be able to tell how much is behind
        // the line. The trigger only when the record carried one.
        text:
            '$from earlier ${from == 1 ? 'message' : 'messages'} were '
            'compacted away by the agent'
            '${trigger == null ? '' : ' ($trigger)'}. What it kept is the '
            'summary below; the transcript file still holds them, and so does '
            'search.',
        at: messages[from].at,
      ),
    );
  }

  for (var i = from; i < messages.length; i++) {
    final message = messages[i];
    final reference = message.subagent;
    if (reference != null) subagents?[out.length] = reference;
    out.add(
      ChatMessage(
        role: message.role,
        text: message.text,
        tool: message.tool,
        thinking: message.thinking,
        at: message.at,
      ),
    );
  }
  return out;
}

/// **Whether a chat view can be built for this session**, as a reading rather
/// than a fact about the agent. Watched, so the view redraws when it settles.
SessionChatView sessionChatView(WidgetRef ref, String sessionId) =>
    ref.watch(sessionChatViewProvider(sessionId));
