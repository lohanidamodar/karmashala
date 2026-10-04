import 'dart:io';

import 'package:karmashala_session_engine/store.dart';
import 'package:path/path.dart' as p;

export 'package:karmashala_session_engine/store.dart'
    show HandoffKind, HandoffRoute, SessionHandoff;

/// **The texts a session is started with**, kept in `session_handoffs` and
/// nowhere else for longer than the agent needs them. A text the agent must
/// read from a file is written to a folder of its session's own under the OS
/// temp directory, deleted once used, when the session ends, or by [sweep].
class SessionHandoffs {
  SessionHandoffs({
    required this.dao,
    required this.root,
    required this.now,
    this.legacy,
  });

  /// The temp root for [dataDirectory]: one per data folder, so a probe's
  /// sweep never touches the real server's files.
  static Directory rootFor(String dataDirectory) {
    var hash = 0x811c9dc5;
    for (final unit in p.normalize(dataDirectory).toLowerCase().codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    final suffix = hash.toRadixString(16).padLeft(8, '0');
    return Directory(p.join(Directory.systemTemp.path, 'karmashala-$suffix'));
  }

  final SessionHandoffDao dao;
  final Directory root;
  final DateTime Function() now;

  /// `<data dir>/handoff`, where launches wrote their files before this.
  final Directory? legacy;

  /// How long a used row, or a file of a session nothing runs, is kept.
  static const keep = Duration(days: 1);

  /// Told of each started session with a row still to use: an opening to
  /// type in, or a file to delete once the agent has it.
  void Function(String sessionId)? onPending;

  /// Records [text] as [sessionId]'s [kind], going by [route]; a route that
  /// delivers it as the launch happens is consumed at once.
  void record(
    String sessionId,
    HandoffKind kind,
    String text,
    HandoffRoute route,
  ) {
    final at = now();
    dao.put(
      SessionHandoff(
        sessionId: sessionId,
        kind: kind,
        text: text,
        route: route,
        createdAt: at,
      ),
    );
    if (route == HandoffRoute.argv) dao.consume(sessionId, at: at, kind: kind);
  }

  /// Writes [text] for [sessionId]'s [kind] and returns its path, or null: a
  /// launch that cannot write a file must still run.
  String? writeFile(String sessionId, HandoffKind kind, String text) {
    try {
      final file = File(p.join(folderOf(sessionId).path, _fileName(kind)));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  Directory folderOf(String sessionId) =>
      Directory(p.join(root.path, _safe(sessionId)));

  /// The row of [sessionId]'s that waits to be typed in, if any.
  SessionHandoff? pendingTyped(String sessionId) {
    for (final kind in const [HandoffKind.opening, HandoffKind.packet]) {
      final row = dao.get(sessionId, kind);
      if (row != null &&
          row.consumedAt == null &&
          row.route == HandoffRoute.typed) {
        return row;
      }
    }
    return null;
  }

  /// [sessionId]'s unconsumed rows that went by file.
  List<SessionHandoff> pendingFiles(String sessionId) => [
    for (final row in dao.forSession(sessionId))
      if (row.consumedAt == null && row.route == HandoffRoute.file) row,
  ];

  /// Marks [sessionId]'s rows — of [kind] alone when given — used, and
  /// deletes their files.
  void consume(String sessionId, {HandoffKind? kind}) {
    dao.consume(sessionId, at: now(), kind: kind);
    if (kind == null) {
      _delete(folderOf(sessionId));
      return;
    }
    _deleteFile(File(p.join(folderOf(sessionId).path, _fileName(kind))));
    _deleteIfEmpty(folderOf(sessionId));
  }

  /// The text a file-route opening of [sessionId]'s stood for, while its row
  /// is kept: what its transcript shows in place of the pointer.
  String? openingBehindPointer(String sessionId) {
    for (final kind in const [HandoffKind.opening, HandoffKind.packet]) {
      final row = dao.get(sessionId, kind);
      if (row != null && row.route == HandoffRoute.file) return row.text;
    }
    return null;
  }

  /// Whether [sessionId]'s agent was pointed at a file for its opening, so
  /// its own title for the conversation names the pointer.
  bool openedByPointer(String sessionId) =>
      openingBehindPointer(sessionId) != null;

  /// Deletes rows used more than [keep] ago, rows and folders of sessions
  /// not in [live] older than that, and every folder of a session that has
  /// no row left. Says how many rows and folders went.
  int sweep({required Set<String> live}) {
    final cutoff = now().subtract(keep);
    var removed = dao.sweep(before: cutoff, live: live);
    try {
      if (!root.existsSync()) return removed;
      for (final entity in root.listSync()) {
        if (entity is! Directory) continue;
        final sessionId = p.basename(entity.path);
        final waiting = pendingFiles(sessionId).isNotEmpty;
        final old = _modified(entity)?.isBefore(cutoff) ?? true;
        if (waiting && (live.contains(sessionId) || !old)) continue;
        if (_delete(entity)) removed++;
      }
      _deleteIfEmpty(root);
    } on Object {
      // An unreadable root sweeps nothing and fails nothing.
    }
    return removed;
  }

  /// Deletes every file under [legacy] whose session is not in [live], and
  /// the folder once it is empty. Run once, on the server's start.
  int sweepLegacy({required Set<String> live}) {
    final directory = legacy;
    if (directory == null) return 0;
    var removed = 0;
    try {
      if (!directory.existsSync()) return 0;
      final kept = {
        for (final id in live) ...[
          'handoff-${_safe(id)}.md',
          'prompt-${_safe(id)}.md',
        ],
      };
      for (final entity in directory.listSync()) {
        if (entity is! File || kept.contains(p.basename(entity.path))) {
          continue;
        }
        if (_deleteFile(entity)) removed++;
      }
      _deleteIfEmpty(directory);
    } on Object {
      // As [sweep].
    }
    return removed;
  }

  static String _fileName(HandoffKind kind) => switch (kind) {
    HandoffKind.opening => 'message.md',
    HandoffKind.packet => 'brief.md',
    HandoffKind.systemPrompt => 'system-prompt.md',
  };

  static String _safe(String sessionId) =>
      sessionId.replaceAll(RegExp('[^A-Za-z0-9-]'), '_');

  static DateTime? _modified(Directory directory) {
    try {
      return directory.statSync().modified;
    } on Object {
      return null;
    }
  }

  static bool _delete(Directory directory) {
    try {
      if (!directory.existsSync()) return false;
      directory.deleteSync(recursive: true);
      return true;
    } on Object {
      // Held open by the agent; the next sweep tries again.
      return false;
    }
  }

  static bool _deleteFile(File file) {
    try {
      if (!file.existsSync()) return false;
      file.deleteSync();
      return true;
    } on Object {
      return false;
    }
  }

  static void _deleteIfEmpty(Directory directory) {
    try {
      if (directory.existsSync() && directory.listSync().isEmpty) {
        directory.deleteSync();
      }
    } on Object {
      // As [_delete].
    }
  }
}

/// The one plain line an agent is handed in place of a text written to
/// [path] — quote-free, so it survives a Windows-native launch, and naming
/// nothing but a message, so an agent's title for it says little.
///
/// A packet ([isPacket]) is the agent's whole brief and ends with what to do,
/// so it is framed as the brief — the standing Claude Code gives a packet
/// appended to its system prompt — not as a document to look at.
String promptFilePointer(String path, {required bool isPacket}) => isPacket
    ? 'Your brief for this session is in the file $path. Read all of it '
          'before doing anything else, treat it as your instructions, and '
          'carry out what it ends with.'
    : 'My opening message to you is in the file $path. Read all of it and '
          'act on it exactly as if I had typed it here.';

/// Whether [text] is a line [promptFilePointer] wrote, now or before this
/// change (a packet then named its file a "handoff brief").
bool isPromptFilePointer(String text) {
  final said = text.trim();
  return said.startsWith('My opening message to you is in the file ') ||
      said.startsWith('Your brief for this session is in the file ') ||
      said.startsWith('Your handoff brief for this session is the file ');
}
