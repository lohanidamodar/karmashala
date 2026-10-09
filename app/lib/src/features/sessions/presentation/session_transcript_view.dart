import '../application/session_active_model_providers.dart';
import '../../workspaces/data/workspace_data.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../snippets/application/snippet_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/shell/side_panel_state.dart';
import '../../../app/shell/workbench.dart' show CompactWorkbenchScope;
import 'transcript_links.dart';
import '../../editor/application/editor_tab_actions.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/dialogs.dart' show showConfirmDialog;
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_checkpoints/checkpoints.dart' show Checkpoint;
import '../../checkpoints/application/checkpoint_providers.dart';
import '../application/session_handoff_service.dart';
import '../application/turn_forks.dart';
import '../application/turn_rewinds.dart';
import 'rewind_dialog.dart';
import 'hunk_review.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/installation_labels.dart';
import '../../artifacts/application/artifact_providers.dart';
import '../../artifacts/domain/artifact_placement.dart';
import '../../artifacts/presentation/artifact_card.dart';
import '../../artifacts/presentation/unplaced_artifacts_strip.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart'
    show Artifact, SessionVisual;
import '../../artifacts/application/visual_providers.dart';
import '../../artifacts/domain/visual_placement.dart';
import '../../artifacts/presentation/session_visual_block.dart';
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
import '../application/session_mention_reads.dart';
import '../application/session_prompt_kinds_providers.dart';
import '../application/session_actions.dart';
import '../application/session_chat_source.dart';
import '../application/session_chat_view_providers.dart';
import '../application/session_engine_provider.dart';
import '../application/session_input.dart';
import '../application/session_providers.dart';
import '../application/session_status_providers.dart';
import '../application/session_turn_interrupt.dart';
import '../application/session_turn_stop.dart';
import 'package:agent_cli/descriptors.dart'
    show AgentActivityStatus, AgentStatusReport, AgentWorkingDetail;
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
import 'working_line.dart';
import 'chat_cards/chat_tool_ask.dart';
import 'chat_cards/pinned_plan_strip.dart';
import 'chat_target_menu.dart';
import 'chat_transcript.dart';
import '../../../core/clipboard/image_clipboard.dart'
    show imageClipboardProvider, saveImageAs;
import 'end_session_action.dart';
import 'switch_agent_control.dart';
import 'session_recap_card.dart';
import 'message_composer.dart';
import 'queued_messages_strip.dart';
import 'operator_chip.dart';
import 'transcript_file_preview.dart';
import 'transcript_image_preview.dart';
import 'transcript_inline_images.dart';
import 'stop_children_offer.dart';
import 'stop_escalation_line.dart';
import 'delegation_card.dart';
import 'session_failed_state.dart';
import 'background_runs_strip.dart';

part 'session_transcript_view/chat_messages.dart';
part 'session_transcript_view/details.dart';
part 'session_transcript_view/footer.dart';
part 'session_transcript_view/header_buttons.dart';
part 'session_transcript_view/places.dart';
part 'session_transcript_view/turn_actions.dart';

/// Whether the agent in [String] session has a prompt or question open.
final _promptOpenProvider = Provider.autoDispose.family<bool, String>(
  (ref, sessionId) => ref.watch(
    agentSessionStatusProvider(sessionId).select(
      (status) =>
          status.asData?.value.hasOpenPrompt == true ||
          status.asData?.value.hasOpenQuestion == true,
    ),
  ),
);

/// The chat transcript for the selected native session, rendered CLI-style. Only
/// conversational events are shown — lifecycle/status noise is filtered out.
class SessionTranscriptView extends ConsumerStatefulWidget {
  const SessionTranscriptView({
    required this.sessionId,
    this.holdForPrompt = false,
    this.seenUntil,
    this.resumesInBackground = false,
    super.key,
  });

  /// See [ChatTranscriptView.seenUntil].
  final DateTime? seenUntil;

  /// The Agent dashboard's peek: a message to a session nothing runs resumes
  /// it where the person is, with no tab opened.
  final bool resumesInBackground;

  final String sessionId;

  /// The phone's session page: while the agent has a prompt or question open,
  /// the box is held with "Answer the prompt above first", as the companion
  /// did — typed text would land in the prompt the dock answers.
  final bool holdForPrompt;

  @override
  ConsumerState<SessionTranscriptView> createState() =>
      _SessionTranscriptViewState();
}

class _SessionTranscriptViewState extends ConsumerState<SessionTranscriptView>
    with
        _TranscriptDetails,
        _TranscriptTurnActions,
        _TranscriptFooter,
        _TranscriptPlaces {
  /// The most of the conversation's height the recap may take.
  static const _recapShare = 0.3;

  /// The same on the phone's page, where 30% of a 640dp screen crowds out
  /// the conversation.
  static const _recapShareCompact = 0.18;

  /// Owned here rather than inside the composer, because something outside the
  /// composer writes to it: a note sent back lands in this box.
  @override
  final _composer = MentionTextController();

  /// Files dropped on the conversation, for the composer to attach.
  @override
  final _dropped = StreamController<List<String>>.broadcast();

  /// Ticks when server files are queued for this session
  /// ([composerAttachmentsProvider]); the composer then **pulls** them
  /// through [_takeQueuedFiles] if it can attach them at once, and otherwise
  /// leaves them queued until it can. Nothing is pushed at a composer that
  /// might refuse it: a file taken and refused was lost after the user had
  /// been told it was sent. With no composer — the transcript still loading —
  /// nobody pulls, and the one that mounts takes what waited.
  @override
  final _filesQueued = ValueNotifier<int>(0);

  /// Ticks to take the conversation to its newest message.
  final _toLatest = ValueNotifier<int>(0);

  /// Ticks to hand the composer the keyboard: a message put back to edit.
  @override
  final _composerFocus = ValueNotifier<int>(0);

  /// Held rather than read in [dispose]: `ref` is unusable once the element is
  /// on its way out, and the draft has to be parked exactly then.
  late final ComposerDrafts _drafts;

  /// [_drafts]' twin for files, held for the same reason.
  late final ComposerAttachments _queuedFiles;

  /// Where half-typed text waits while no view of its session is open.
  late final ParkedDrafts _parked;

  /// A parked draft is looked for once, on the first frame of a session.
  bool _restoreDue = true;

  /// Set before the draft is parked, because parking it notifies this widget's
  /// own listener on the same provider and `ref` is dead by then.
  bool _leaving = false;

  /// The running or latest turn's start and token count, off its working
  /// line — see the status listener in [build].
  DateTime? _turnSince;
  int? _turnTokens;

  /// Told whether the box holds unsent text, held for the same reason.
  late final ComposersHoldingText _holding;

  /// The session [_holding] was last told about, and what it was told.
  String? _heldFor;
  var _held = false;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(composerDraftProvider.notifier);
    _queuedFiles = ref.read(composerAttachmentsProvider.notifier);
    _parked = ref.read(parkedDraftsProvider);
    _holding = ref.read(composersHoldingTextProvider.notifier);
    _composer.addListener(_tellHolding);
  }

  /// Whether the box holds text not yet sent, for the dashboard's peek to
  /// stay open over. After the frame: text set while the tree builds may not
  /// change a provider then.
  void _tellHolding() {
    final holding = _composer.text.trim().isNotEmpty;
    final id = widget.sessionId;
    if (holding == _held && id == _heldFor) return;
    final was = _heldFor;
    _held = holding;
    _heldFor = id;
    final tell = _holding;
    Future.microtask(() {
      if (was != null && was != id) tell.mark(was, holding: false);
      tell.mark(id, holding: holding);
    });
  }

  @override
  void didUpdateWidget(SessionTranscriptView old) {
    super.didUpdateWidget(old);
    if (old.holdForPrompt != widget.holdForPrompt) _footer = null;
    if (old.sessionId != widget.sessionId) {
      // Text typed for the last session is kept for it, never sent to this.
      _parked.park(old.sessionId, _composer.text);
      _composer.clear();
      _restoreDue = true;
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
    _parked.park(widget.sessionId, _composer.text);
    _composer.removeListener(_tellHolding);
    if (_heldFor case final id? when _held) {
      final tell = _holding;
      Future.microtask(() => tell.mark(id, holding: false));
    }
    _composer.dispose();
    unawaited(_dropped.close());
    _filesQueued.dispose();
    _toLatest.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  /// Takes the reader to the open ask: the conversation's newest message,
  /// where its card hangs, then the card itself wholly in view.
  @override
  void _showAsk() {
    _toLatest.value++;
    ref.read(chatAskRevealsProvider.notifier).request(widget.sessionId);
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

  /// Puts back what this session's last closed view left typed — only into
  /// an empty box; otherwise it stays parked for the next one.
  void _restoreParked() {
    if (_leaving || !_restoreDue) return;
    _restoreDue = false;
    if (_composer.text.trim().isNotEmpty) return;
    final parked = _parked.take(widget.sessionId);
    if (parked == null) return;
    _composer.value = TextEditingValue(
      text: parked,
      selection: TextSelection.collapsed(offset: parked.length),
    );
  }

  /// A queued message that failed, back in the box to send again — appended
  /// after any draft, never sent.
  @override
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
  @override
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
    // The running turn's last token count, kept for its footer once it ends:
    // the line a finished turn leaves names no count.
    ref.listen(agentSessionStatusProvider(widget.sessionId), (_, next) {
      final report = next.asData?.value;
      if (report?.turnStatus != AgentActivityStatus.working) return;
      final working = report!.working;
      final since = working?.since;
      final kept = _turnSince;
      // A new turn, not the same start read a second apart.
      if (since != null &&
          (kept == null ||
              since.difference(kept).abs() > AgentWorkingDetail.sinceSlack)) {
        _turnTokens = null;
      }
      _turnSince = since ?? kept;
      _turnTokens = working?.tokens ?? _turnTokens;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _restoreParked();
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
    // A click opens a web link in the browser; on touch it asks first.
    final onLinkTap = _openLink;

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
                                  // Watched: a catalogue that arrives later
                                  // relabels turns already drawn.
                                  modelLabelOf: ref.watch(
                                    sessionModelLabelerProvider(
                                      widget.sessionId,
                                    ),
                                  ),
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
    // Kept alive while the view is: Esc reads it, and a read of a provider
    // nobody holds would start from "loading".
    ref.listen(sessionTurnWorkingProvider(widget.sessionId), (_, _) {});
    // Board N2's "Stop · Esc", from anywhere in the chat: the composer, the
    // conversation, a button. Only while the turn runs — the action is
    // disabled otherwise, so the key falls through to whatever else Esc
    // means there.
    return Actions(
      actions: {_StopTurnIntent: _stopAction},
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _StopTurnIntent(),
        },
        // Files dropped anywhere on the conversation are attached in the box.
        child: FileDropZone(
          name: 'chat ${widget.sessionId}',
          onFiles: _onFilesDropped,
          builder: (context, hovering) => FileDropHighlight(
            label: 'Drop to attach',
            visible: hovering,
            // Pictures the conversation names are drawn in it, read through
            // the server wherever the session runs.
            child: TranscriptInlineImages(
              place: _placeImage,
              onOpen: _openImage,
              child: ChatTargetMenuScope(menu: _targetMenu, child: body),
            ),
          ),
        ),
      ),
    );
  }

  late final _stopAction = _StopTurnAction(this);

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
    final artifacts =
        ref.watch(sessionArtifactsProvider(widget.sessionId)).value ??
        const <Artifact>[];
    final visuals =
        ref.watch(sessionVisualsProvider(widget.sessionId)).value ??
        const <SessionVisual>[];
    return transcript.when(
      loading: () =>
          const Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
      error: (e, _) => Center(child: Text('$e')),
      data: (messages) {
        final detail = _detailWithArtifacts(messages, artifacts, visuals);
        final unplaced = _placement.unplaced;
        final trailingVisuals = [
          if (earlier == 0) ..._visualPlacement.earlier,
          ..._visualPlacement.trailing,
        ];
        return HunkReviewHost(
          key: ValueKey('hunks-${widget.sessionId}'),
          sessionId: widget.sessionId,
          place: _placeEditedFile,
          openFile: _openEditedFile,
          child: ChatTranscriptView(
            // Per session: this view outlives a switch within its group, and an
            // unkeyed list kept the last session's scroll offset.
            key: ValueKey(widget.sessionId),
            sentencePerLine: ref.watch(
              settingsControllerProvider.select((s) => s.chatSentencePerLine),
            ),
            toLatest: _toLatest,
            messages: messages,
            seenUntil: widget.seenUntil,
            earlier: earlier,
            onLoadEarlier: earlier > 0
                ? () => unawaited(
                    ref
                        .read(serverTranscriptsProvider)
                        .loadOlder(widget.sessionId),
                  )
                : null,
            firstOrdinal: firstOrdinal,
            agentId: _agentId(),
            turn: turn,
            turnActions: _turnActionsFor(messages, turn, active: active),
            resolveHostPath: resolveHostPath,
            // Paths in the conversation are clickable, and a click reveals
            // rather than opens — see [_openPath].
            onPathTap: _openPath,
            filePreviewBuilder: _filePreview,
            onLinkTap: onLinkTap,
            // What the parent's `Task(…)` row never showed. Collapsed and
            // unread until opened — one session's turns came to 1,485 MiB.
            detailBuilder: detail,
            // Null when Notes is off: the transcript never learns the
            // feature exists, so there is nothing left behind to hide.
            onSaveNote: notesEnabled ? _saveNote : null,
            workingLine: WorkingLine(
              sessionId: widget.sessionId,
              escStops: true,
            ),
            // Stop was pressed and the turn has ended since: its footer says
            // so whatever the agent wrote, as not every agent writes a line.
            lastTurnStoppedAt: ref.watch(
              turnStopsProvider.select((stops) {
                final stop = stops[widget.sessionId];
                return stop != null && stop.settled ? stop.pressedAt : null;
              }),
            ),
            // The word the agent left on its screen as the turn ended.
            lastTurnVerb: ref.watch(
              agentSessionStatusProvider(widget.sessionId).select((status) {
                final report = status.asData?.value;
                return report?.turnStatus == AgentActivityStatus.idle
                    ? report?.working?.word
                    : null;
              }),
            ),
            lastTurnTokens: _turnTokens,
            trailing: trailingVisuals.isEmpty
                ? null
                : SessionVisualBlocks(
                    key: const ValueKey('session-visuals-trailing'),
                    sessionId: widget.sessionId,
                    visualIds: trailingVisuals,
                  ),
            footer: unplaced.isEmpty
                ? footer
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UnplacedArtifactsStrip(artifacts: unplaced),
                      footer,
                    ],
                  ),
            emptyBuilder: (standard) => SessionEmptyOrFailed(
              sessionId: widget.sessionId,
              otherwise: standard,
            ),
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
      },
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
}
