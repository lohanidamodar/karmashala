import 'package:agent_cli/descriptors.dart'
    show
        AgentRegistry,
        AgentRunForm,
        ConversationPrompt,
        ConversationRewind,
        OwnRewindPoints,
        RewindMode;
import 'package:agent_cli/read.dart' show RewindMarker, rewoundRows;
import 'package:karmashala_checkpoints/checkpoints.dart'
    show
        Checkpoint,
        CheckpointConflict,
        CheckpointRestoreAnswer,
        RestorePreview;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show SessionRewind;
import 'package:karmashala_session_engine/store.dart'
    show SessionDao, SessionMessage, SessionMessageDao, SessionMessageRole;

import '../../acp/acp_extensions.dart';
import '../../domain/uuid.dart';
import 'rewind_cuts.dart';
import 'terminal_rewind.dart';

/// Why a rewind waits: the agent is working.
const String kRewindWhileWorking =
    'The agent is working. Stop it first, then rewind.';

/// The file half of a rewind, over the server's checkpoints.
abstract interface class RewindFiles {
  /// The checkpoints a turn's start names, one per repository it touched, or
  /// the one [checkpointId] names. Throws in words when there are none.
  List<Checkpoint> checkpointsFor({
    required String sessionId,
    String? checkpointId,
    int? turn,
  });

  /// Why [checkpoint]'s files cannot be restored for [sessionId] now, or null.
  String? refusal(Checkpoint checkpoint, {required String sessionId});

  Future<RestorePreview> preview(Checkpoint checkpoint);

  /// The conflict a restore without confirm would be refused with.
  Future<CheckpointConflict?> conflict(Checkpoint checkpoint);

  Future<CheckpointRestoreAnswer> restore(
    Checkpoint checkpoint, {
    required bool confirm,
  });
}

/// One turn the transcript shows: the person's words, and whether a rewind
/// already folded it.
typedef _Turn = ({String text, bool rewound});

/// **Rewinding a session to before one of the person's messages**, owned by
/// the server (`sessions.rewind`, `session_rewind`): its files back from
/// Karmashala's checkpoint of that turn's start — any agent, and every file,
/// not only those the agent's own undo tracks — its conversation cut in the
/// agent, or both. Done with the session's queue held, so no message is
/// delivered into a half-rewound session.
///
/// The conversation cut: a chat session is restarted resumed up to the entry
/// before the message (`--resume-session-at`), its id kept; a terminal
/// session's own `/rewind` menu is driven, the screen read after each key.
class SessionRewinds {
  SessionRewinds({
    required this.sessions,
    required this.agentOf,
    required this.registry,
    required this.messages,
    required this.transcriptLines,
    required this.cuts,
    required this.runsHere,
    required this.end,
    required this.resume,
    this.files,
    this.terminal,
    this.turnRunning,
    this.holdQueue,
    this.releaseQueue,
    this.messagesChanged,
    this.log,
    String Function()? newId,
    DateTime Function()? now,
  }) : _newId = newId ?? newUuid,
       _now = now ?? (() => DateTime.now().toUtc());

  final SessionDao sessions;

  /// The agent an installation id names.
  final String? Function(String installationId) agentOf;
  final AgentRegistry Function() registry;
  final SessionMessageDao messages;

  /// The lines of the agent's own record of [sessionId]'s conversation, or
  /// null when it cannot be read here.
  final Future<List<String>?> Function(String sessionId) transcriptLines;
  final RewindCuts cuts;
  final bool Function(String sessionId) runsHere;
  final Future<void> Function(String sessionId) end;
  final Future<void> Function(String sessionId) resume;

  /// Null: this server keeps no checkpoints, and no rewind restores files.
  final RewindFiles? files;
  final TerminalRewind? terminal;
  final bool Function(String sessionId)? turnRunning;
  final void Function(String sessionId)? holdQueue;
  final void Function(String sessionId)? releaseQueue;
  final void Function(String sessionId)? messagesChanged;
  final void Function(String message)? log;
  final String Function() _newId;
  final DateTime Function() _now;

  Future<Map<String, Object?>> rewind(SessionRewind request) async {
    final mode =
        RewindMode.parse(request.mode) ??
        (throw ArgumentError('mode is one of both, conversation or code.'));
    final sessionId = request.sessionId;
    final session =
        sessions.getById(sessionId) ??
        (throw StateError('This session no longer exists.'));
    if (session.isArchived) {
      throw StateError('This session is archived; restore it to rewind.');
    }
    if (turnRunning?.call(sessionId) ?? false) {
      throw StateError(kRewindWhileWorking);
    }
    final agentId = agentOf(session.agentInstallationId);
    final agents = registry();
    final chat = agentId != null && agents.formOf(agentId) == AgentRunForm.chat;
    final agentName = agentId == null
        ? 'The agent'
        : agents.foldedNameOf(agentId);
    final cut = mode.cutsConversation ? _cutOf(agents, agentId) : null;
    if (mode.cutsConversation && cut == null) {
      throw StateError(
        '$agentName cannot rewind its conversation from Karmashala. Choose '
        'Code only, or rewind in its own terminal.',
      );
    }
    final words = request.words.trim();

    // The turns undone, counted on the transcript when the server keeps it.
    int? later;
    if (chat) {
      final turns = _chatTurns(sessionId);
      final at = _pick(
        [for (final t in turns) t.text],
        request.turnIndex,
        words,
      );
      if (at == null) {
        throw StateError(
          'That message is not in this session\'s transcript any more. '
          'Nothing was changed.',
        );
      }
      if (turns[at].rewound) {
        throw StateError('That message was already rewound.');
      }
      later = turns.skip(at + 1).where((t) => !t.rewound).length;
    }

    // Where the agent's conversation is cut: before the message's entry.
    ConversationPrompt? prompt;
    var back = 0;
    if (cut != null) {
      final lines = await transcriptLines(sessionId);
      if (lines == null) {
        throw StateError(
          "$agentName's own record of this conversation cannot be read "
          'here, so its conversation cannot be cut. Nothing was changed.',
        );
      }
      final prompts = cut.promptsOf(lines, leaf: cuts.cutOf(sessionId));
      final at = _pick(
        [for (final p in prompts) p.text],
        later == null ? request.turnIndex : prompts.length - 1 - later,
        words,
      );
      if (at == null) {
        throw StateError(
          "That message is not in $agentName's own record of the "
          'conversation (it may be before a compaction), so the '
          'conversation cannot be cut there. Nothing was changed.',
        );
      }
      prompt = prompts[at];
      back = prompts.length - 1 - at;
      later ??= back;
    }
    // The message's own turn goes too.
    final undone = later == null ? null : later + 1;

    final checkpoints = mode.restoresCode
        ? _checkpoints(request)
        : const <Checkpoint>[];
    final refusals = [
      for (final checkpoint in checkpoints)
        if (files!.refusal(checkpoint, sessionId: sessionId) case final why?)
          '${checkpoint.repository.path}: $why',
    ];

    if (request.preview) {
      final repositories = <Map<String, Object?>>[];
      final outside = <String>{};
      var restores = 0;
      for (final checkpoint in checkpoints) {
        final preview = await files!.preview(checkpoint);
        restores += preview.files.length;
        outside.addAll(preview.outside);
        repositories.add({
          'repository': checkpoint.repository.path,
          'checkpointId': checkpoint.id,
          'files': preview.files,
          'outside': preview.outside,
          'headMoved': preview.headMoved,
        });
      }
      return {
        'preview': true,
        'mode': mode.name,
        'turns': ?undone,
        'files': restores,
        'outside': outside.toList()..sort(),
        'headMoved': repositories.any((r) => r['headMoved'] == true),
        'repositories': repositories,
        'refusals': refusals,
        'conversation': _conversationNote(mode, chat, prompt, agentName),
      };
    }
    if (refusals.isNotEmpty) {
      throw StateError('Nothing was changed. ${refusals.join(' ')}');
    }
    if (cut != null && !chat && terminal == null) {
      throw StateError(
        'This server cannot answer a terminal\'s rewind menu. Nothing was '
        'changed.',
      );
    }
    if (cut != null && !chat && !runsHere(sessionId)) {
      throw StateError(
        "$agentName's rewind menu is in its terminal, and nothing runs it. "
        'Open the terminal, then rewind. Nothing was changed.',
      );
    }

    holdQueue?.call(sessionId);
    try {
      final restored = await _restore(checkpoints, confirm: request.confirm);
      final count = restored.fold<int>(0, (sum, r) => sum + r.files);
      if (cut != null) {
        try {
          if (chat) {
            await _cutChat(sessionId, prompt!, undone ?? 1, mode);
          } else {
            await terminal!.rewind(
              sessionId,
              back: back,
              menu: cut.menu,
              words: words,
            );
          }
        } on Object catch (error) {
          final why = error is StateError ? error.message : '$error';
          throw StateError(
            count == 0 || checkpoints.isEmpty
                ? why
                : '$why The files were already restored ($count '
                      'file${count == 1 ? '' : 's'}).',
          );
        }
      } else if (chat) {
        _note(
          sessionId,
          'Files put back to before "${_short(words)}" '
          '($count file${count == 1 ? '' : 's'}). The conversation is '
          'unchanged: the agent still remembers what came after.',
        );
      }
      log?.call(
        'Rewound $sessionId (${mode.name}) to before its message '
        '${request.turnIndex}: $count files, '
        '${cut == null ? 'conversation kept' : 'conversation cut by ${chat ? 'resume-at' : 'menu'}'}',
      );
      return {
        'rewound': true,
        'mode': mode.name,
        'turns': ?undone,
        'files': count,
        'composerText': words,
        'repositories': [
          for (final r in restored)
            {
              'repository': r.repository,
              'files': r.files,
              'undoCheckpointId': ?r.undo,
            },
        ],
        'conversation': _conversationNote(mode, chat, prompt, agentName),
      };
    } finally {
      releaseQueue?.call(sessionId);
    }
  }

  ConversationRewind? _cutOf(AgentRegistry agents, String? agentId) {
    if (agentId == null) return null;
    final rewind = agents.adapterFor(agents.foldedIdOf(agentId))?.rewind;
    return rewind is OwnRewindPoints ? rewind.conversation : null;
  }

  List<_Turn> _chatTurns(String sessionId) {
    final rows = messages.listAfter(sessionId);
    String role(int i) => rows[i].messageId == AcpExtensions.rewoundMessageId
        ? 'rewound'
        : rows[i].role.name;
    bool opens(int i) =>
        rows[i].role == SessionMessageRole.user &&
        !(rows[i].messageId ?? '').startsWith(
          AcpExtensions.compactionMessageId,
        ) &&
        !_interruption.hasMatch(rows[i].text.trim());
    final rewound = rewoundRows(
      rows.length,
      roleAt: role,
      textAt: (i) => rows[i].text,
      opensTurn: opens,
    );
    return [
      for (var i = 0; i < rows.length; i++)
        if (opens(i)) (text: rows[i].text, rewound: rewound[i]),
    ];
  }

  static final _interruption = RegExp(
    r'^\[Request interrupted by user[^\]]*\]$',
  );

  /// The index among [texts] of the message [words], at [hint] when it says
  /// them there, else the nearest that does; with no words, [hint] itself.
  static int? _pick(List<String> texts, int? hint, String words) {
    final said = _plain(words);
    bool says(int i) {
      if (said.isEmpty) return true;
      final text = _plain(texts[i]);
      return text.contains(said) || (text.isNotEmpty && said.contains(text));
    }

    if (hint != null && hint >= 0 && hint < texts.length && says(hint)) {
      return hint;
    }
    if (said.isEmpty) return null;
    int? best;
    for (var i = texts.length - 1; i >= 0; i--) {
      if (!says(i)) continue;
      if (best == null ||
          (hint != null && (i - hint).abs() < (best - hint).abs())) {
        best = i;
      }
    }
    return best;
  }

  static String _plain(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _short(String words) {
    final line = _plain(words);
    return line.length <= 60 ? line : '${line.substring(0, 57)}…';
  }

  List<Checkpoint> _checkpoints(SessionRewind request) {
    final work =
        files ??
        (throw StateError(
          'This server keeps no checkpoints, so no files can be restored. '
          'Choose Conversation only.',
        ));
    if (request.checkpointTurn == null && request.checkpointId == null) {
      throw StateError(
        'No checkpoint was taken at this turn, so its files cannot be '
        'restored. Choose Conversation only.',
      );
    }
    return work.checkpointsFor(
      sessionId: request.sessionId,
      checkpointId: request.checkpointId,
      turn: request.checkpointId == null ? request.checkpointTurn : null,
    );
  }

  Future<List<({String repository, int files, String? undo})>> _restore(
    List<Checkpoint> checkpoints, {
    required bool confirm,
  }) async {
    if (checkpoints.isEmpty) return const [];
    final work = files!;
    // Every moved tree is found before any is written.
    if (!confirm) {
      for (final checkpoint in checkpoints) {
        final conflict = await work.conflict(checkpoint);
        if (conflict != null) {
          throw StateError(
            'Files changed outside the agent since then. Nothing was '
            'changed; they are saved as checkpoint '
            '${conflict.safetyCheckpoint?.sequence ?? 'already recorded'}. '
            'Rewind again to restore anyway.',
          );
        }
      }
    }
    return [
      for (final checkpoint in checkpoints)
        await work.restore(checkpoint, confirm: confirm).then((answer) {
          final outcome = answer.outcomeOrThrow;
          return (
            repository: checkpoint.repository.path,
            files: outcome.files.length,
            undo: outcome.alreadyThere ? null : outcome.safetyCheckpoint?.id,
          );
        }),
    ];
  }

  /// The chat form's cut: the entry before [prompt] kept for every load
  /// until a message is sent ([RewindCuts]), a rewind row in the transcript,
  /// and the agent restarted when it runs. A cut before the first message is
  /// a fresh conversation in the same session.
  Future<void> _cutChat(
    String sessionId,
    ConversationPrompt prompt,
    int turns,
    RewindMode mode,
  ) async {
    final running = runsHere(sessionId);
    if (running) await end(sessionId);
    final entry = prompt.parentUuid;
    if (entry == null) {
      cuts.taken(sessionId);
      sessions.updateExternalSessionId(sessionId, '');
    } else {
      cuts.cut(sessionId, entry);
    }
    _append(
      sessionId,
      SessionMessageRole.notice,
      RewindMarker(turns: turns, mode: mode).text,
      messageId: AcpExtensions.rewoundMessageId,
    );
    if (!running) return;
    try {
      await resume(sessionId);
    } on Object catch (error) {
      throw StateError(
        'The conversation was cut, but the agent did not start again '
        '($error). It starts cut when you send a message.',
      );
    }
  }

  void _note(String sessionId, String text) =>
      _append(sessionId, SessionMessageRole.notice, text);

  void _append(
    String sessionId,
    SessionMessageRole role,
    String text, {
    String? messageId,
  }) {
    final at = _now();
    messages.append(
      SessionMessage(
        id: _newId(),
        sessionId: sessionId,
        role: role,
        text: text,
        messageId: messageId,
        createdAt: at,
        updatedAt: at,
      ),
    );
    messagesChanged?.call(sessionId);
  }

  static Map<String, Object?> _conversationNote(
    RewindMode mode,
    bool chat,
    ConversationPrompt? prompt,
    String agentName,
  ) => {
    'cut': mode.cutsConversation,
    if (mode.cutsConversation) 'how': chat ? 'resume' : 'menu',
    if (mode.cutsConversation) 'fresh': prompt?.parentUuid == null,
    'note': switch (mode) {
      RewindMode.code =>
        '$agentName keeps the whole conversation and still believes it made '
            'the edits since.',
      _ when chat =>
        '$agentName restarts remembering the conversation only up to before '
            'this message.',
      _ =>
        "Karmashala answers $agentName's own /rewind menu in its terminal, "
            'restoring the conversation only.',
    },
  };
}
