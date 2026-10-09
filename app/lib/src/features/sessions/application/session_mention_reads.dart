import 'dart:convert';

import 'package:karmashala_session/session.dart';
import 'package:karmashala_terminal_runtime/screen_reading.dart';
import 'package:riverpod/riverpod.dart';

import '../../../app/shell/quick_open/repo_file_index.dart';
import '../../files/data/files_client.dart';
import '../../git/data/git_data.dart';
import '../../overview/application/overview_reads.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import 'session_mentions.dart';
import 'session_providers.dart';
import 'session_working_directory.dart';

/// [MentionReads] for session [_sessionId], from what this app already
/// holds: the server's walk of the checkout, git at the server, this
/// window's terminal panes, and the sessions' records.
class _SessionMentionReads implements MentionReads {
  _SessionMentionReads(this._ref, this._sessionId);

  final Ref _ref;
  final String _sessionId;

  @override
  Future<({List<String> files, String? gitignore})> files() async {
    final root = sessionWorkingDirectory(_ref, _sessionId);
    if (root == null) return (files: const <String>[], gitignore: null);
    final indexed = await _ref.read(repoFileIndexProvider).index(root);
    String? gitignore;
    for (final file in indexed) {
      if (file.relativePath != '.gitignore') continue;
      try {
        final bytes = await _ref.read(filesClientProvider).read(file.path);
        gitignore = utf8.decode(bytes, allowMalformed: true);
      } on Object {
        // Unreadable: nothing is hidden, which is the safe way round.
      }
      break;
    }
    return (
      files: [for (final file in indexed) file.relativePath],
      gitignore: gitignore,
    );
  }

  @override
  Future<String> diff(String base) async {
    final root = sessionWorkingDirectory(_ref, _sessionId);
    if (root == null) throw StateError('This session has no checkout to diff');
    return _ref.read(gitDataProvider).diff(root, base: base);
  }

  @override
  List<MentionTerminal> terminals() {
    final panes = _ref.read(paneSessionsProvider);
    final controller = _ref.read(terminalSessionsControllerProvider.notifier);
    final own = panes.terminalPanesOf(_sessionId);
    final shells = [
      for (final tab in _ref.read(terminalTabsProvider))
        for (final pane in tab.layout.panes)
          if (panes.sessionOf(pane) == null) pane,
    ];
    return [
      for (final pane in {...own, ...shells})
        if (controller.instanceFor(pane) != null)
          MentionTerminal(id: pane, title: controller.titleForPane(pane)),
    ];
  }

  @override
  String? terminalTail(String id, int lines) {
    final instance = _ref
        .read(terminalSessionsControllerProvider.notifier)
        .instanceFor(id);
    if (instance == null) return null;
    return terminalTailLines(instance.terminal, lines: lines).join('\n');
  }

  List<Session> _live() => [
    for (final row in _ref.read(sessionsDataProvider).getAll())
      if (row.archivedAt == null && row.id != _sessionId) row,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  List<MentionSession> sessions() => [
    for (final row in _live()) MentionSession(id: row.id, title: row.title),
  ];

  @override
  List<MentionSession> subagents() => [
    for (final row in _live())
      if (row.parentSessionId == _sessionId)
        MentionSession(id: row.id, title: row.title),
  ];

  @override
  Future<String?> lastAnswer(String id) async =>
      (await _ref.read(overviewReaderProvider).lastAnswer(id)).text;
}

/// What "@" offers in session [String]'s composer, and how it is sent.
final sessionMentionsProvider = Provider.family<SessionMentions, String>(
  (ref, sessionId) => SessionMentions(_SessionMentionReads(ref, sessionId)),
);
