import '../../workspaces/data/workspace_data.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../snippets/application/snippet_providers.dart';
import '../application/session_activity_providers.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/shell/side_panel_state.dart';
import '../../../app/shell/workbench.dart' show CompactWorkbenchScope;
import '../../../app/widgets/adaptive_modal.dart';
import '../../editor/application/editor_tab_actions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/installation_labels.dart';
import 'package:agent_cli/read.dart';
import '../../cli_detection/presentation/subagent_turns_tile.dart';
import '../../editor/application/code_editor_providers.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/process.dart';
import '../../file_explorer/application/file_explorer_providers.dart';
import '../../files/data/files_client.dart';
import '../../files/data/pick_server.dart';
import '../../files/presentation/take_photo.dart';
import 'package:karmashala_ui/picking.dart' show PickServer;
import 'package:karmashala_files/values.dart' show FileStat;
import '../../notes/application/composer_draft.dart';
import '../../notes/application/notes_providers.dart';
import '../../terminal/application/system_terminal_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart' show isChatPane;
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import '../application/acp_session_providers.dart';
import '../application/session_commands_providers.dart';
import '../application/session_prompt_kinds_providers.dart';
import '../application/session_actions.dart';
import '../application/session_chat_source.dart';
import '../application/session_chat_view_providers.dart';
import '../application/session_engine_provider.dart';
import '../application/session_input.dart';
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';
import '../application/session_turn_interrupt.dart';
import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentStatusReport;
import '../application/session_ui_providers.dart';
import '../../media/application/session_media_providers.dart'
    show sessionImageFetchProvider;
import '../data/server_transcripts.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../../core/file_drop/file_drop_router.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_session/events.dart';
import 'package:agent_cli/stream.dart';
import 'package:karmashala_session/launch.dart';
import 'activity_strip.dart';
import 'chat_cards/chat_tool_ask.dart';
import 'chat_cards/pinned_plan_strip.dart';
import 'chat_transcript.dart';
import 'end_session_action.dart';
import 'switch_agent_control.dart';
import 'session_recap_card.dart';
import 'message_composer.dart';
import 'queued_messages_strip.dart';
import 'operator_chip.dart';
import 'transcript_image_preview.dart';
import 'stop_children_offer.dart';
import 'delegation_card.dart';

/// The chat transcript for the selected native session, rendered CLI-style. Only
/// conversational events are shown — lifecycle/status noise is filtered out.
class SessionTranscriptView extends ConsumerStatefulWidget {
  const SessionTranscriptView({
    required this.sessionId,
    this.holdForPrompt = false,
    super.key,
  });

  final String sessionId;

  /// The phone's session page: while the agent has a prompt or question open,
  /// the box is held with "Answer the prompt above first", as the companion
  /// did — typed text would land in the prompt the dock answers.
  final bool holdForPrompt;

  @override
  ConsumerState<SessionTranscriptView> createState() =>
      _SessionTranscriptViewState();
}

class _SessionTranscriptViewState extends ConsumerState<SessionTranscriptView> {
  /// The most of the footer the composer may take; the strips get the rest.
  static const _composerShare = 0.7;

  /// The most of the conversation's height the recap may take.
  static const _recapShare = 0.3;

  /// The same on the phone's page, where 30% of a 640dp screen crowds out
  /// the conversation.
  static const _recapShareCompact = 0.18;

  /// Owned here rather than inside the composer, because something outside the
  /// composer writes to it: a note sent back lands in this box.
  final _composer = TextEditingController();

  /// Files dropped on the conversation, for the composer to attach.
  final _dropped = StreamController<List<String>>.broadcast();

  /// Ticks when server files are queued for this session
  /// ([composerAttachmentsProvider]); the composer then **pulls** them
  /// through [_takeQueuedFiles] if it can attach them at once, and otherwise
  /// leaves them queued until it can. Nothing is pushed at a composer that
  /// might refuse it: a file taken and refused was lost after the user had
  /// been told it was sent. With no composer — the transcript still loading —
  /// nobody pulls, and the one that mounts takes what waited.
  final _filesQueued = ValueNotifier<int>(0);

  /// The key of the message last sent and not yet taken, kept so a retry of
  /// the same words is the same request to the server; a new message mints
  /// its own.
  String? _sendKey;
  String? _keyedText;

  /// Which delegated agent hangs under which row, by the row's index in the
  /// whole transcript. Read back by [ChatTranscriptView.detailBuilder].
  var _subagents = <int, SubagentRef>{};

  /// Children started together, by the row their folded card hangs under.
  var _delegations = <int, List<DelegationCall>>{};

  /// Replaced only when [_subagents] changes: the transcript's rows compare
  /// their callbacks, and a fresh closure on every poll would rebuild them all.
  late MessageDetailBuilder _detailBuilder = _subagentDetailFor(_subagents);

  /// The resolver for [_resolverEnvironment], kept for the same reason.
  String? Function(String)? _resolver;
  String? _resolverEnvironment;

  /// Held rather than read in [dispose]: `ref` is unusable once the element is
  /// on its way out, and the draft has to be parked exactly then.
  late final ComposerDrafts _drafts;

  /// [_drafts]' twin for files, held for the same reason.
  late final ComposerAttachments _queuedFiles;

  /// Set before the draft is parked, because parking it notifies this widget's
  /// own listener on the same provider and `ref` is dead by then.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(composerDraftProvider.notifier);
    _queuedFiles = ref.read(composerAttachmentsProvider.notifier);
  }

  @override
  void didUpdateWidget(SessionTranscriptView old) {
    super.didUpdateWidget(old);
    if (old.holdForPrompt != widget.holdForPrompt) _footer = null;
    if (old.sessionId != widget.sessionId) {
      _footer = null;
      _resolver = null;
      _sendKey = null;
      _keyedText = null;
      // Another session's queue: the composer looks at it now.
      _filesQueued.value++;
    }
  }

  @override
  void dispose() {
    // The workbench unmounts the conversation when it moves to another session,
    // so half-typed text is parked where the next mount already looks for it.
    _leaving = true;
    final draft = _composer.text;
    if (draft.trim().isNotEmpty) _drafts.queue(widget.sessionId, draft);
    _composer.dispose();
    unawaited(_dropped.close());
    _filesQueued.dispose();
    super.dispose();
  }

  void _onFilesDropped(List<String> paths) {
    // No composer while the transcript is still loading or failed to.
    if (!_dropped.hasListener) {
      _say('There is no message box to attach them to yet.');
      return;
    }
    _dropped.add(paths);
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

  /// A queued message that failed, back in the box to send again — appended
  /// after any draft, never sent.
  void _backToComposer(String text) {
    if (_leaving) return;
    final existing = _composer.text.trimRight();
    _composer.text = existing.isEmpty ? text : '$existing\n\n$text';
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
  }

  /// Takes whatever files were queued for this session, by the path its agent
  /// reads — called only by the composer, and only when it attaches them in
  /// the same call ([MessageComposer.takeServerFiles], [_filesQueued]). A
  /// method tear-off, so the footer built once keeps an equal callback.
  List<String> _takeQueuedFiles() {
    if (_leaving) return const [];
    final queued = _queuedFiles.take(widget.sessionId);
    if (queued == null) return const [];
    return [for (final file in queued) file.path];
  }

  /// Keeps [message] as a note, word for word, remembering where it was taken
  /// from. One tap: no dialog, no title, nothing rewritten.
  void _saveNote(ChatMessage message, int ordinal) {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
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
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    final environmentId = ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.environmentId;
    if (environmentId == null) return null;
    if (_resolver != null && _resolverEnvironment == environmentId) {
      return _resolver;
    }
    _resolverEnvironment = environmentId;
    return _resolver = (path) => ref
        .read(editorActionsProvider)
        .windowsPathFor(
          EnvironmentPath(environmentId: environmentId, path: path),
        );
  }

  /// The agent this session is with, for the empty state's mark; null for a
  /// session whose installation is not known here.
  String? _agentId() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    return ref
        .read(agentInstallationsDataProvider)
        .getById(session.agentInstallationId)
        ?.agentId;
  }

  /// The server the agent runs on, for the composer's attachments: browsed in
  /// the environment the session's agent runs in, a WSL or SSH one included.
  PickServer _pickServer() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    final environmentId = session == null
        ? null
        : ref
              .read(agentInstallationsDataProvider)
              .getById(session.agentInstallationId)
              ?.environmentId;
    return ref.read(
      pickServerProvider(environmentId ?? localHostEnvironmentId),
    );
  }

  /// What hangs under a row: the subagent it spawned, and the ask about it
  /// while one is open.
  MessageDetailBuilder _subagentDetailFor(Map<int, SubagentRef> subagents) =>
      (message, ordinal) {
        final reference = subagents[ordinal];
        final callId = message.pending ? message.pendingToolUseId : null;
        final ask = callId == null
            ? null
            : ChatToolAsk(
                sessionId: widget.sessionId,
                toolUseId: callId,
                toolName: message.tool?.name,
              );
        final Widget? lead;
        if (reference == null) {
          final calls = _delegations[ordinal];
          lead = calls == null
              ? null
              : DelegationGroupCard(
                  parentSessionId: widget.sessionId,
                  calls: calls,
                );
        } else {
          lead = SubagentTurnsTile(
            reference: reference,
            resolveHostPath: _hostPathResolver(),
            sessionId: widget.sessionId,
          );
        }
        if (lead == null || ask == null) return lead ?? ask;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [lead, ask],
        );
      };

  /// Where this session's agent was standing. Null means **unknown**, never
  /// "the repository root", so the fallback is made here and out loud.
  EnvironmentPath? _workingDirectory() {
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    if (session == null) return null;
    return session.workingDirectory ??
        ref.read(workspaceDataProvider).repository(session.repositoryId)?.path;
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
    // The phone's page has no file panel beside it: a file opens as a tab.
    final compact = CompactWorkbenchScope.of(context);
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
        .read(environmentsDataProvider)
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

    // The server looks, wherever the session's files are: this machine, WSL
    // or an SSH host.
    final FileStat stat;
    try {
      stat = await ref.read(filesClientProvider).stat(path);
    } on FilesException catch (error) {
      _say(error.message);
      return;
    }
    if (!mounted) return;
    if (!stat.exists) {
      _say('$resolved is not on disk.');
      return;
    }
    final isDirectory = stat.isDirectory;

    if (compact) {
      if (isDirectory) {
        _say('$resolved is a folder.');
      } else {
        ref.read(editorTabActionsProvider).openAt(path, line: parsed.line);
      }
      return;
    }

    // Inside the checkout the panel is rooted at: show it there, where the
    // reader already is.
    final root = ref.read(fileTreeRootProvider);
    if (root != null && isUnderFileTreeRoot(root, path)) {
      ref
          .read(fileRevealTargetProvider.notifier)
          .reveal(FileRevealTarget(path: path, isDirectory: isDirectory));
      if (ref.read(sidePanelProvider) != SidePanelSurface.files) {
        ref.read(sidePanelProvider.notifier).select(SidePanelSurface.files);
      }
      return;
    }

    // Outside it there is no row to select, so the host's own file manager is
    // all that is left. `canReveal` starts no process, so asking first is free.
    final revealer = ref.read(revealInFileManagerProvider);
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

  /// A link the agent wrote, tapped on a touch screen: asked about first, since
  /// a stray tap while scrolling must not leave the app.
  Future<void> _openLink(String href) async {
    final uri = Uri.tryParse(href);
    if (uri != null && !uri.hasScheme) {
      await _openPath(href);
      return;
    }
    if (uri == null ||
        !(uri.isScheme('http') ||
            uri.isScheme('https') ||
            uri.isScheme('mailto'))) {
      _say('Only web links open from here: $href');
      return;
    }
    final go = await showAdaptiveModal<bool>(
      context: context,
      title: 'Open in the browser?',
      builder: (context) => _OpenLinkBody(uri: uri),
    );
    if (go != true || !mounted) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _say('Nothing on this device could open $href.');
      }
    } on Exception {
      _say('Nothing on this device could open $href.');
    }
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
    // Files offered from an open tab: the composer is told, and takes them
    // when it can attach them ([_filesQueued]).
    ref.listen(composerAttachmentsProvider, (_, next) {
      if (!_leaving && next.containsKey(widget.sessionId)) {
        _filesQueued.value++;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _takeQueuedNote();
    });
    final session = ref.read(sessionsDataProvider).getById(widget.sessionId);
    // A PTY-hosted session's conversation lives in the agent's own transcript
    // (see `SessionTranscriptLocator`): stdout carries no structured stream.
    // An ACP session's is the server's rows, read down the same path.
    final acp = ref.watch(isAcpSessionProvider(widget.sessionId));
    final fromPty = acp || session?.surface == SessionSurface.pane;
    // An ACP row is live only while its row says so: a failed or ended one
    // is resumed by the next message, and the hint says that.
    final active = acp
        ? session?.status.claimsLive ?? false
        : fromPty || ref.read(sessionEngineProvider).isActive(widget.sessionId);
    final footer = _footerFor(active);
    final recapShare = CompactWorkbenchScope.of(context)
        ? _recapShareCompact
        : _recapShare;
    // Links stay inert under a pointer, as they were; on touch they ask.
    final onLinkTap = UiDensity.of(context).isTouch ? _openLink : null;

    // **No header** (board N2, owner 2026-09-28): the conversation starts right
    // under the tab strip. The tab already names the session and shows its
    // state, and the pane's status line — the same in both views — holds the
    // session's controls; a second row of them here was two places for one.
    // Pictures in its rows come through the server when it is elsewhere.
    final body = TranscriptImageSource(
      fetch: ref.watch(sessionImageFetchProvider(widget.sessionId)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Above the messages and outside their scroll: a digest you
                  // have to scroll back to is of a conversation already re-read.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: box.maxHeight * recapShare,
                    ),
                    child: SessionRecapCard(sessionId: widget.sessionId),
                  ),
                  // Its own consumer: a poll of the transcript redraws the
                  // conversation, not the header, the recap or the composer.
                  Expanded(
                    child: Consumer(
                      builder: (context, ref, _) {
                        final caps = ref.watch(capabilitiesProvider);
                        final agentRecord = fromPty
                            ? ref.watch(
                                sessionChatTranscriptProvider(widget.sessionId),
                              )
                            : null;
                        // What the server holds beyond these rows, and why it
                        // has none — only when it read them (Stage 0 step 6).
                        final window = caps.chatViaServer && agentRecord != null
                            ? ref
                                  .read(serverTranscriptsProvider)
                                  .windowFor(
                                    widget.sessionId,
                                    agentRecord.asData?.value,
                                  )
                            : null;
                        final transcript = agentRecord != null
                            ? agentRecord.whenData(
                                (messages) => _fromTranscript(
                                  messages,
                                  earlier: window?.from ?? 0,
                                ),
                              )
                            : ref
                                  .watch(
                                    sessionTranscriptProvider(widget.sessionId),
                                  )
                                  .whenData(_toMessages);
                        // Whether a chat rendering is possible for **this
                        // session** — a reading, not a registry lookup. The
                        // server's own reading, when it has one, wins.
                        var reading = fromPty
                            ? sessionChatView(ref, widget.sessionId)
                            : const SessionChatView.unread(prior: true);
                        final absence = window?.absence;
                        if (absence != null) {
                          reading = SessionChatView.read(
                            absence,
                            prior: reading.prior,
                            path: window?.path,
                          );
                        }
                        // Past a compaction the view draws nothing older, so
                        // there is nothing earlier worth asking for.
                        final compacted =
                            transcript.asData?.value.firstOrNull?.role ==
                            kCompactionNoticeRole;
                        final earlier =
                            window != null && window.hasOlder && !compacted
                            ? window.from
                            : 0;
                        return _conversation(
                          transcript: transcript,
                          // The badge's reading only while a process is behind
                          // the session: a killed agent's last status can stay
                          // "working", which kept its final turn live — and
                          // unfolded — forever. Nothing running, the turn is over.
                          // An ACP status is the server's runtime speaking,
                          // never a dead process's last word.
                          turn:
                              acp ||
                                  sessionHasLiveProcess(ref, widget.sessionId)
                              ? ref.watch(
                                  agentSessionStatusProvider(
                                    widget.sessionId,
                                  ).select(
                                    (s) => transcriptTurnFor(s.asData?.value),
                                  ),
                                )
                              : TranscriptTurn.idle,
                          resolveHostPath: _hostPathResolver(),
                          notesEnabled: notesEnabled,
                          active:
                              fromPty ||
                              ref
                                  .read(sessionEngineProvider)
                                  .isActive(widget.sessionId),
                          chatAvailable: !fromPty || reading.hasChatView,
                          reading: reading,
                          fromPty: fromPty,
                          // A server elsewhere that cannot read transcripts:
                          // this machine's disk has none of its sessions.
                          serverTooOld:
                              fromPty &&
                              !caps.chatViaServer &&
                              !caps.readsServerDisk,
                          earlier: earlier,
                          firstOrdinal: window?.from ?? 0,
                          // Whether there is a terminal to point at: the user
                          // can switch, so the sentences must be true. A chat
                          // pane is this view, not a terminal.
                          hasTerminal: switch (sessionTerminalPane(
                            ref,
                            widget.sessionId,
                          )) {
                            final paneId? => !isChatPane(paneId),
                            null => false,
                          },
                          onLinkTap: onLinkTap,
                          footer: footer,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    // Files dropped anywhere on the conversation are attached in the box.
    return FileDropZone(
      name: 'chat ${widget.sessionId}',
      onFiles: _onFilesDropped,
      builder: (context, hovering) => FileDropHighlight(
        label: 'Drop to attach',
        visible: hovering,
        child: body,
      ),
    );
  }

  Widget _conversation({
    required AsyncValue<List<ChatMessage>> transcript,
    required TranscriptTurn turn,
    required String? Function(String)? resolveHostPath,
    required bool notesEnabled,
    required bool active,
    required bool chatAvailable,
    required SessionChatView reading,
    required bool fromPty,
    required bool serverTooOld,
    required int earlier,
    required int firstOrdinal,
    required bool hasTerminal,
    required ValueChanged<String>? onLinkTap,
    required Widget footer,
  }) {
    return transcript.when(
      loading: () =>
          const Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
      error: (e, _) => Center(child: Text('$e')),
      data: (messages) => ChatTranscriptView(
        // Per session: this view outlives a switch within its group, and an
        // unkeyed list kept the last session's scroll offset.
        key: ValueKey(widget.sessionId),
        messages: messages,
        earlier: earlier,
        onLoadEarlier: earlier > 0
            ? () => unawaited(
                ref.read(serverTranscriptsProvider).loadOlder(widget.sessionId),
              )
            : null,
        firstOrdinal: firstOrdinal,
        agentId: _agentId(),
        turn: turn,
        resolveHostPath: resolveHostPath,
        // Paths in the conversation are clickable, and a click reveals
        // rather than opens — see [_openPath].
        onPathTap: _openPath,
        onLinkTap: onLinkTap,
        // What the parent's `Task(…)` row never showed. Collapsed and
        // unread until opened — one session's turns came to 1,485 MiB.
        detailBuilder: _detailBuilder,
        // Null when Notes is off: the transcript never learns the
        // feature exists, so there is nothing left behind to hide.
        onSaveNote: notesEnabled ? _saveNote : null,
        footer: footer,
        emptyHint: _emptyHint(
          chatAvailable: chatAvailable,
          reading: reading,
          fromPty: fromPty,
          serverTooOld: serverTooOld,
          active: active,
          hasTerminal: hasTerminal,
        ),
      ),
    );
  }

  Widget? _footer;
  bool? _footerActive;

  /// The strips and the composer, built once per [active]: the same instance
  /// every poll, so a new transcript never rebuilds the box being typed in.
  Widget _footerFor(bool active) {
    if (_footer != null && _footerActive == active) return _footer!;
    _footerActive = active;
    return _footer = Actions(
      actions: {_StopTurnIntent: _StopTurnAction(this)},
      child: Shortcuts(
        // Board N2's "Stop · Esc": Esc in the composer stops the running turn.
        // Only while one runs — the action is disabled otherwise, so the key
        // falls through to whatever else Esc means there.
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _StopTurnIntent(),
        },
        child: _footerBody(active),
      ),
    );
  }

  /// Whether this session has a call in flight: what makes Esc a stop.
  bool get _turnRunning => ref
      .read(sessionOutstandingCallsProvider(widget.sessionId))
      .calls
      .isNotEmpty;

  Future<void> _send(String text) async {
    // `/operator` first: typing it is the person letting this session operate
    // Karmashala. It is taken off the message; alone, it is the whole act.
    final afterOperator = textAfterOperatorCommand(text);
    if (afterOperator != null) {
      await setOperatorGrant(
        context,
        ref,
        widget.sessionId,
        granted: true,
        confirm: false,
      );
      if (afterOperator.isEmpty) {
        _say('This session may now operate Karmashala.');
        return;
      }
      text = '$kOperatorGrantedNote\n\n$afterOperator';
    }
    if (text != _keyedText) {
      _keyedText = text;
      _sendKey = newSessionInputId();
    }
    await ref
        .read(sessionActionsProvider)
        .continueSession(widget.sessionId, text, requestId: _sendKey);
    _keyedText = null;
    _sendKey = null;
  }

  /// Stops the running turn the way its CLI's own terminal would: an Esc,
  /// pressed by the server when it offers it, else typed into the agent's
  /// pane. Said, not silent, when nothing runs the session.
  void _interruptTurn() {
    offerToStopChildren(context, ref, widget.sessionId);
    unawaited(
      ref.read(sessionTurnInterruptProvider)(widget.sessionId).then((why) {
        if (why != null) _say(why);
      }),
    );
  }

  /// The snippet library, as the composer's menu lists it.
  List<ComposerSnippet> _snippets() => [
    for (final snippet in ref.read(commandSnippetsProvider))
      ComposerSnippet(label: snippet.label, text: snippet.command),
  ];

  /// The agent's slash commands, as the composer's palette lists them. Only
  /// an ACP agent announces any.
  List<ComposerCommand> _commands() => [
    for (final command in ref.read(sessionCommandsProvider(widget.sessionId)))
      ComposerCommand(
        name: command.name,
        description: command.description,
        hint: command.hint,
      ),
  ];

  /// The activity line over the composer. The delivery strip sits on the
  /// composer's channel: its prompt actions send through `continueSession`.
  Widget _footerBody(bool active) {
    // A phone's grants are watched here: the footer is built once.
    Widget composer({required bool prompted}) => Consumer(
      builder: (context, ref, _) {
        final caps = ref.watch(capabilitiesProvider);
        // A session that is not running is resumed to take the message.
        final refusal = !caps.maySend
            ? kPromptNotGranted
            : !active && !caps.mayStart
            ? kStartNotGranted
            : null;
        return MessageComposer(
          controller: _composer,
          // Mode, model and stats are on the pane's status bar (owner,
          // 2026-09-28); switching agent is the composer's (2026-10-03).
          chips: [
            if (caps.switchAgent)
              SwitchAgentControl(sessionId: widget.sessionId),
          ],
          // Read when the menu opens, never watched: the footer is
          // built once, and the library changing must not rebuild it.
          snippets: _snippets,
          commands: _commands,
          // Read when the chips draw, like the commands: never watched.
          imagesGoAsImages: () =>
              ref.read(sessionTakesImagesProvider(widget.sessionId)),
          // Read per paste or attach, like the snippets: never watched.
          server: _pickServer,
          droppedFiles: _dropped.stream,
          takeServerFiles: _takeQueuedFiles,
          serverFilesWaiting: _filesQueued,
          attaches: caps.mayAttach,
          camera: () => devicePhotosFor(context, ref),
          enabled: !prompted && refusal == null,
          hintText:
              refusal ??
              (prompted
                  ? 'Answer the prompt above first'
                  : active
                  // No emoji: the old hint named a 🖼 that is nowhere
                  // in the composer; the attach tooltip does.
                  ? 'Message the agent…'
                  : 'Type to continue this session…'),
          onSend: _send,
        );
      },
    );
    return LayoutBuilder(
      builder: (context, box) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // What was sent while the turn ran, waiting at the server below
          // the transcript it will join: it scrolls in whatever the
          // composer leaves, and may not push the box away.
          Flexible(
            child: SingleChildScrollView(
              primary: false,
              child: QueuedMessagesStrip(
                sessionId: widget.sessionId,
                onBackToComposer: _backToComposer,
              ),
            ),
          ),
          // Directly above the box and outside the scroll, so a long queue
          // never hides the running turn or its Stop.
          PinnedPlanStrip(sessionId: widget.sessionId),
          ActivityStrip(sessionId: widget.sessionId, onStop: _interruptTurn),
          ConstrainedBox(
            // A long draft may not crowd an approval out of sight.
            constraints: BoxConstraints(
              maxHeight: box.maxHeight * _composerShare,
            ),
            child: !widget.holdForPrompt
                ? composer(prompted: false)
                : Consumer(
                    builder: (context, ref, _) => composer(
                      // Watched here and only here: the footer is built once.
                      prompted: ref.watch(
                        agentSessionStatusProvider(widget.sessionId).select(
                          (status) =>
                              status.asData?.value.hasOpenPrompt == true ||
                              status.asData?.value.hasOpenQuestion == true,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// What to say when there is nothing to render. Each branch reads the same
  /// `sessionTerminalPane` the workbench does, so the two cannot disagree.
  String _emptyHint({
    required bool chatAvailable,
    required SessionChatView reading,
    required bool fromPty,
    required bool serverTooOld,
    required bool active,
    required bool hasTerminal,
  }) {
    if (serverTooOld) {
      return 'This server is older than the app. Update it to see the '
          'conversation here.';
    }
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

  /// Each agent of a switched thread by name — with where it lives when two
  /// installations of one agent took turns in it.
  TranscriptAgent? Function(String) _agentsIn(
    List<TranscriptMessage> messages,
  ) {
    final rows = ref.read(agentInstallationsDataProvider);
    final labels = installationLabelsOf(
      {for (final message in messages) ?message.agentInstallationId},
      rows: rows,
      environments: ref.read(environmentsDataProvider),
      registry: ref.read(agentRegistryProvider),
    );
    return (installationId) {
      final agentId = rows.getById(installationId)?.agentId;
      final name = labels[installationId];
      if (agentId == null || name == null) return null;
      return (name: name, agentId: agentId);
    };
  }

  /// The agent's own transcript as chat messages. The subagent a row spawned
  /// travels beside them, not inside [ChatMessage], which has no room for it.
  List<ChatMessage> _fromTranscript(
    List<TranscriptMessage> messages, {
    int earlier = 0,
  }) {
    final subagents = <int, SubagentRef>{};
    final out = chatMessagesFromTranscript(
      messages,
      subagents: subagents,
      earlier: earlier,
      agentOf: _agentsIn(messages),
    );
    final delegations = delegationGroups(out);
    if (!mapEquals(subagents, _subagents) ||
        delegationGroupsKey(delegations) != delegationGroupsKey(_delegations)) {
      _subagents = subagents;
      _delegations = delegations;
      _detailBuilder = _subagentDetailFor(subagents);
    }
    return out;
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

/// Esc in the chat's footer: stop the running turn.
class _StopTurnIntent extends Intent {
  const _StopTurnIntent();
}

/// Enabled only while a call is in flight, so an idle Esc is not consumed —
/// and never reaches the agent, where a stray one clears or rewinds its input.
class _StopTurnAction extends Action<_StopTurnIntent> {
  _StopTurnAction(this._view);

  final _SessionTranscriptViewState _view;

  @override
  bool isEnabled(_StopTurnIntent intent) => _view.mounted && _view._turnRunning;

  @override
  Object? invoke(_StopTurnIntent intent) {
    _view._interruptTurn();
    return null;
  }
}

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

/// The link in full, so the reader sees where it goes, and the two answers.
class _OpenLinkBody extends StatelessWidget {
  const _OpenLinkBody({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectableText(
            '$uri',
            style: MonoStyles.body.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: Touch.gap),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Open'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The pane of this window [sessionId] can be *shown* in, or null when it has
/// none. Read, not watched: a widget that must follow it watches
/// [paneOfSessionProvider].
String? sessionTerminalPane(WidgetRef ref, String sessionId) =>
    ref.read(paneSessionsProvider).paneOf(sessionId);

/// The agent a switched session's row names, as its turns are labelled.
typedef TranscriptAgent = ({String name, String agentId});

/// A CLI transcript as chat messages, with a compacted session's history shown
/// **once** — the summary restates everything before the last boundary.
@visibleForTesting
List<ChatMessage> chatMessagesFromTranscript(
  List<TranscriptMessage> messages, {
  Map<int, SubagentRef>? subagents,
  int earlier = 0,
  TranscriptAgent? Function(String installationId)? agentOf,
}) {
  // The **last** boundary: a session compacted twice has restated its history
  // twice, and only the newest summary covers all of it. [earlier] rows come
  // before [messages] (a server-read window), so its first row can be one.
  var from = 0;
  CompactionBoundary? boundary;
  final first = earlier > 0 ? 0 : 1;
  for (var i = messages.length - 1; i >= first; i--) {
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
    final compacted = earlier + from;
    out.add(
      ChatMessage(
        role: kCompactionNoticeRole,
        // The count, because a reader must be able to tell how much is behind
        // the line. The trigger only when the record carried one.
        text:
            '$compacted earlier '
            '${compacted == 1 ? 'message' : 'messages'} were '
            'compacted away by the agent'
            '${trigger == null ? '' : ' ($trigger)'}. What it kept is the '
            'summary below; the transcript file still holds them, and so does '
            'search.',
        at: messages[from].at,
      ),
    );
  }

  // In a switched session an agent is named where it starts speaking — the
  // thread's first agent row, and the first after each switch — not on every
  // turn it goes on taking: the divider already says who took over.
  String? lastNamed;
  for (var i = from; i < messages.length; i++) {
    final message = messages[i];
    final reference = message.subagent;
    if (reference != null) subagents?[out.length] = reference;
    final installation = message.agentInstallationId;
    final switching = message.role == kAgentSwitchRole;
    final named =
        installation != null &&
        (switching || (message.role == 'agent' && installation != lastNamed));
    final agent = named ? agentOf?.call(installation) : null;
    if (switching) {
      lastNamed = null;
    } else if (named) {
      lastNamed = installation;
    }
    out.add(
      ChatMessage(
        role: switching ? kAgentSwitchNoticeRole : message.role,
        text: message.text,
        tool: message.tool,
        thinking: message.thinking,
        at: message.at,
        pending: message.pendingToolUseId != null,
        pendingToolUseId: message.pendingToolUseId,
        agentName: named ? agent?.name ?? 'another agent' : null,
        agentId: agent?.agentId,
      ),
    );
  }
  return out;
}

/// The status badge's reading as the transcript needs it. A failed session's
/// turn is over, so it is idle here.
TranscriptTurn transcriptTurnFor(AgentStatusReport? report) =>
    switch (report?.status) {
      AgentActivityStatus.working => TranscriptTurn.working,
      AgentActivityStatus.awaitingApproval => TranscriptTurn.awaitingUser,
      AgentActivityStatus.idle ||
      AgentActivityStatus.failed => TranscriptTurn.idle,
      AgentActivityStatus.unknown || null => TranscriptTurn.unknown,
    };

/// **Whether a chat view can be built for this session**, as a reading rather
/// than a fact about the agent. Watched, so the view redraws when it settles.
SessionChatView sessionChatView(WidgetRef ref, String sessionId) =>
    ref.watch(sessionChatViewProvider(sessionId));
