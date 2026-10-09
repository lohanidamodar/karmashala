import 'package:agent_cli/process.dart';
import 'package:karmashala_git/git.dart'
    show DiffLine, DiffLineKind, FileDiffStat;
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/session.dart';
import 'package:riverpod/riverpod.dart';

import '../../explorer/application/checkout_default.dart';
import '../../explorer/application/session_context.dart';
import '../../git/application/diff_tab_actions.dart';
import '../../git/application/parsed_diff.dart';
import '../../git/data/git_data.dart';
import '../../sessions/application/diff_hunks.dart';
import '../../sessions/application/session_changed_files_providers.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_signals.dart';
import '../../workspaces/data/workspace_data.dart';
import '../domain/document_id.dart';

export '../../git/application/diff_tab_actions.dart' show DiffTarget;
export '../../sessions/application/diff_hunks.dart' show EditHunk;

/// One uncommitted change of a file, placed on the lines the editor shows.
class EditorHunk {
  const EditorHunk({
    required this.edit,
    required this.startLine,
    required this.endLine,
    required this.addedLines,
    required this.removedAbove,
    required this.quote,
    this.replacedLines = const {},
  });

  /// The hunk Keep and Revert act on: the same one a diff card offers.
  final EditHunk edit;

  /// 1-based, inclusive: what a comment names. A change that only took lines
  /// out spans the line it left them above.
  final int startLine;
  final int endLine;

  /// 1-based lines the change wrote.
  final List<int> addedLines;

  /// 1-based lines that have lines taken out just above them, with nothing
  /// written in their place.
  final List<int> removedAbove;

  /// Its removed and added lines as a diff reads them, for a comment to quote.
  final String quote;

  int get index => edit.index;

  /// Of [addedLines], those written in place of lines taken out.
  final Set<int> replacedLines;

  String get range =>
      startLine == endLine ? '$startLine' : '$startLine–$endLine';

  /// "line 7", or "lines 2–4".
  String get lines => startLine == endLine ? 'line $range' : 'lines $range';
}

/// [lines], a file's diff against git, as hunks on the file's own lines.
/// [numbers] is [newFileLineNumbers] of them.
List<EditorHunk> editorHunksOf(
  String path,
  List<DiffLine> lines,
  List<int?> numbers,
) {
  final hunks = diffHunks(path, lines);
  final out = <EditorHunk>[];
  for (var h = 0; h < hunks.length; h++) {
    final hunk = hunks[h];
    final end = h + 1 < hunks.length ? hunks[h + 1].firstChange : lines.length;
    final added = <int>[];
    final removedAbove = <int>[];
    final replaced = <int>{};
    var afterRemoval = false;
    final quote = StringBuffer();
    int? lastNumber;
    for (var r = hunk.header ?? 0; r < hunk.firstChange; r++) {
      lastNumber = numbers[r] ?? lastNumber;
    }
    var r = hunk.firstChange;
    while (r < end) {
      final kind = lines[r].kind;
      if (kind == DiffLineKind.hunk || kind == DiffLineKind.meta) break;
      if (kind == DiffLineKind.removed) {
        var k = r;
        while (k < end && lines[k].kind == DiffLineKind.removed) {
          quote.writeln(lines[k].text);
          k++;
        }
        final followedByAdd = k < end && lines[k].kind == DiffLineKind.added;
        afterRemoval = followedByAdd;
        if (!followedByAdd) {
          final next = k < lines.length ? numbers[k] : null;
          final at = next ?? (lastNumber ?? 0) + 1;
          removedAbove.add(at);
        }
        r = k;
        continue;
      }
      if (kind == DiffLineKind.added) {
        quote.writeln(lines[r].text);
        if (numbers[r] case final n?) {
          added.add(n);
          if (afterRemoval) replaced.add(n);
        }
      } else {
        afterRemoval = false;
      }
      lastNumber = numbers[r] ?? lastNumber;
      r++;
    }
    final touched = [...added, ...removedAbove]..sort();
    if (touched.isEmpty) continue;
    out.add(
      EditorHunk(
        edit: hunk,
        startLine: touched.first,
        endLine: touched.last,
        addedLines: added,
        removedAbove: removedAbove,
        replacedLines: replaced,
        quote: quote.toString().trimRight(),
      ),
    );
  }
  return out;
}

/// The hunk the caret on 1-based [line] is in, or null.
EditorHunk? hunkAtLine(List<EditorHunk> hunks, int line) {
  for (final hunk in hunks) {
    if (line >= hunk.startLine && line <= hunk.endLine) return hunk;
  }
  return null;
}

/// Who an open file's changes are reviewed with: the session working in the
/// checkout that holds it, and where that file is in the checkout.
class EditorReviewTarget {
  const EditorReviewTarget({
    required this.sessionId,
    required this.sessionTitle,
    required this.repositoryId,
    required this.checkout,
    required this.relativePath,
  });

  final String sessionId;
  final String sessionTitle;
  final String repositoryId;
  final EnvironmentPath checkout;

  /// As git spells it, `/`-separated.
  final String relativePath;

  DiffTarget get diff => DiffTarget(checkout: checkout, path: relativePath);

  @override
  bool operator ==(Object other) =>
      other is EditorReviewTarget &&
      other.sessionId == sessionId &&
      other.sessionTitle == sessionTitle &&
      other.repositoryId == repositoryId &&
      other.checkout == checkout &&
      other.relativePath == relativePath;

  @override
  int get hashCode => Object.hash(
    sessionId,
    sessionTitle,
    repositoryId,
    checkout,
    relativePath,
  );
}

/// The session whose changes to [file] are reviewed: of the live sessions
/// working in the checkout holding it, the focused one, else the newest. Null
/// when no checkout holds the file or no session works in it. Paths are
/// compared within one environment only, so a WSL or SSH file needs a
/// checkout there.
EditorReviewTarget? resolveEditorReview({
  required EnvironmentPath file,
  required List<Repository> repositories,
  required List<({Session session, List<Repository> checkouts})> sessions,
  String? focusedSessionId,
}) {
  Repository? holder;
  for (final repository in repositories) {
    if (!isUnder(repository.path, file)) continue;
    if (holder == null || pathDepth(repository.path) > pathDepth(holder.path)) {
      holder = repository;
    }
  }
  final relative = holder == null ? null : relativeSubPath(holder.path, file);
  if (holder == null || relative == null) return null;
  final working = [
    for (final entry in sessions)
      if (!entry.session.isArchived &&
          entry.checkouts.any((c) => c.id == holder!.id))
        entry.session,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  if (working.isEmpty) return null;
  final chosen =
      working.where((s) => s.id == focusedSessionId).firstOrNull ??
      working.first;
  return EditorReviewTarget(
    sessionId: chosen.id,
    sessionTitle: chosen.title,
    repositoryId: holder.id,
    checkout: holder.path,
    relativePath: relative,
  );
}

/// [resolveEditorReview] for an open document, by its id.
final editorReviewTargetProvider = Provider.autoDispose
    .family<EditorReviewTarget?, String>((ref, documentId) {
      ref.watchSessionKinds({
        SessionChangeKind.membership,
        SessionChangeKind.status,
        SessionChangeKind.placement,
        SessionChangeKind.title,
      });
      final focused = ref.watch(focusedSessionIdProvider);
      final workspace = ref.read(workspaceDataProvider);
      return resolveEditorReview(
        file: documentPathOf(documentId),
        repositories: workspace.repositories,
        sessions: [
          for (final session in ref.read(sessionsDataProvider).getAll())
            (session: session, checkouts: sessionCheckouts(ref, session)),
        ],
        focusedSessionId: focused,
      );
    });

/// The uncommitted hunks of [target]'s file, against `HEAD` as the Changes
/// panel counts them, read through the server wherever the checkout is.
final editorHunksProvider = Provider.autoDispose
    .family<AsyncValue<List<EditorHunk>>, DiffTarget>(
      (ref, target) => ref
          .watch(parsedDiffProvider(target))
          .whenData(
            (parsed) =>
                editorHunksOf(target.path, parsed.lines, parsed.newLineNumbers),
          ),
    );

/// A file of the session's, in the "Changes in this session" list.
class SessionReviewFile {
  const SessionReviewFile({
    required this.relativePath,
    required this.documentId,
    this.added,
    this.removed,
  });

  final String relativePath;
  final String documentId;

  /// Uncommitted lines, where git counted them; null for none or unknown.
  final int? added;
  final int? removed;

  String get name => relativePath.split('/').last;
}

/// The files of [changed] — what the session says it touched, as its own
/// environment spells them — inside [checkout], each with what git counts
/// uncommitted. When the session names none, [stats]' files stand in: what is
/// uncommitted in the checkout it works in.
List<SessionReviewFile> sessionReviewFiles({
  required EnvironmentPath checkout,
  required List<String>? changed,
  required Map<String, FileDiffStat> stats,
}) {
  final windows =
      checkout.path.contains(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(checkout.path);
  String? inside(String path) {
    final absolute =
        path.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(path);
    if (!absolute) return path.replaceAll(r'\', '/');
    return relativeSubPath(
      checkout,
      EnvironmentPath(environmentId: checkout.environmentId, path: path),
    );
  }

  final relatives = <String>{
    for (final path
        in (changed == null || changed.isEmpty) ? stats.keys : changed)
      ?inside(path),
  };
  final root = checkout.path.endsWith('/') || checkout.path.endsWith(r'\')
      ? checkout.path.substring(0, checkout.path.length - 1)
      : checkout.path;
  return [
    for (final relative in relatives.toList()..sort())
      SessionReviewFile(
        relativePath: relative,
        documentId: documentIdOf(
          EnvironmentPath(
            environmentId: checkout.environmentId,
            path: windows
                ? '$root\\${relative.replaceAll('/', r'\')}'
                : '$root/$relative',
          ),
        ),
        added: stats[relative]?.added,
        removed: stats[relative]?.removed,
      ),
  ];
}

/// [sessionReviewFiles] for [target]'s session and checkout.
final sessionReviewFilesProvider = FutureProvider.autoDispose
    .family<List<SessionReviewFile>, EditorReviewTarget>((ref, target) async {
      final report = await ref.watch(
        sessionChangedFilesProvider(target.sessionId).future,
      );
      Map<String, FileDiffStat> stats;
      try {
        stats = await ref.read(gitDataProvider).fileDiffStats(target.checkout);
      } on Object {
        stats = const {};
      }
      return sessionReviewFiles(
        checkout: target.checkout,
        changed: [for (final file in report.files) file.path],
        stats: stats,
      );
    });
