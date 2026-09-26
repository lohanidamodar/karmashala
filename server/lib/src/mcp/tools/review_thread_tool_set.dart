import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_environments/store.dart';
import 'package:karmashala_git/git.dart';
import 'package:karmashala_git/store.dart';
import 'package:karmashala_projects/store.dart';
import 'package:karmashala_session_engine/store.dart';
import 'package:karmashala_store/database.dart';

import 'server_tool_context.dart';
import 'server_tool_set.dart';

/// Where review anchors are hashed: the current git blob of a file in a
/// checkout. Nothing takes a sha from a caller — every write computes it from
/// disk, and a file git cannot hash gets none.
abstract interface class ReviewAnchors {
  /// Whether this server can read [repositoryId]'s files. A checkout it cannot
  /// (WSL, SSH) is the app's, and its review calls are handed to the app.
  bool reaches(String repositoryId);

  /// The content fingerprint of each of [paths] as they stand on disk. A path
  /// git could not hash is absent, which the caller reads as "cannot tell" and
  /// never as unchanged.
  Future<Map<String, String>> shasFor(String repositoryId, List<String> paths);
}

/// [ReviewAnchors] for the checkouts in this machine's own environment, read
/// with the git on this machine's `PATH`.
class LocalReviewAnchors implements ReviewAnchors {
  LocalReviewAnchors(
    AppDatabase database, {
    CommandRunner runner = const LocalCommandRunner(),
    bool? windows,
  }) : _repositories = RepositoryDao(database),
       _environments = ExecutionEnvironmentDao(database),
       _git = GitService(runner),
       _windows = windows ?? Platform.isWindows;

  final RepositoryDao _repositories;
  final ExecutionEnvironmentDao _environments;
  final GitService _git;
  final bool _windows;

  /// An unknown repository is reached: there is nothing of it to hash, which
  /// the tools answer as the app did — an anchor of unknown attachment.
  @override
  bool reaches(String repositoryId) {
    final repository = _repositories.getById(repositoryId);
    if (repository == null) return true;
    final environment = _environments.getById(repository.path.environmentId);
    return switch (environment?.kind) {
      EnvironmentKind.localPosix => !_windows,
      EnvironmentKind.windowsNative => _windows,
      _ => false,
    };
  }

  @override
  Future<Map<String, String>> shasFor(
    String repositoryId,
    List<String> paths,
  ) async {
    final repository = _repositories.getById(repositoryId);
    if (repository == null) return const {};
    try {
      return await _git.hashObjects(repository.path, paths);
    } on Object {
      // A git that will not answer is "cannot tell", never a silent attached.
      return const {};
    }
  }
}

/// `review_thread_list`, `review_thread_get`, `review_thread_add`,
/// `review_thread_reply`, `review_thread_status`: review comments an agent
/// can raise and answer — a row with an anchor a human can click. An agent's
/// thread opens as [ReviewThreadStatus.open] and no more. Calls about a
/// checkout this server cannot read are handed to the app, which hashes it.
class ReviewThreadToolSet extends ServerToolSet {
  ReviewThreadToolSet(this._context, {ReviewAnchors? anchors})
    : _anchors = anchors ?? LocalReviewAnchors(_context.database),
      _threads = ReviewThreadDao(_context.database),
      _sessions = SessionDao(_context.database);

  final ServerToolContext _context;
  final ReviewAnchors _anchors;
  final ReviewThreadDao _threads;
  final SessionDao _sessions;

  @override
  List<Map<String, Object?>> get schemas => reviewThreadToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) {
    String? repositoryId;
    try {
      repositoryId = switch (tool) {
        'review_thread_list' ||
        'review_thread_add' => _repositoryFor(arguments, callerSessionId),
        _ => _threads.getById(_id(arguments))?.repositoryId,
      };
    } on ArgumentError {
      // Refused below, in the order the app refused it.
      repositoryId = null;
    }
    if (repositoryId != null && !_anchors.reaches(repositoryId)) return null;
    return runTool(() => _run(tool, arguments, callerSessionId));
  }

  Future<Object?> _run(
    String tool,
    Map<String, dynamic> args,
    String? caller,
  ) => switch (tool) {
    'review_thread_list' => _list(args, caller),
    'review_thread_get' => _get(args),
    'review_thread_add' => _add(args, caller),
    'review_thread_reply' => _reply(args, caller),
    'review_thread_status' => _status(args),
    _ => throw ArgumentError('Unknown tool: $tool'),
  };

  Future<Object?> _list(Map<String, dynamic> args, String? caller) async {
    final repositoryId = _repositoryFor(args, caller);
    final index = await _indexFor(repositoryId);
    final path = (args['path'] as String?)?.trim();
    final wanted = _statusFilter(args['status']);
    return <String, Object?>{
      'repositoryId': repositoryId,
      'threads': [
        for (final entry
            in path == null || path.isEmpty ? index.all : index.forPath(path))
          if (wanted == null || wanted.contains(entry.thread.status))
            _threadJson(entry),
      ],
    };
  }

  Future<Object?> _get(Map<String, dynamic> args) async {
    final id = _id(args);
    final entry = await _anchored(id);
    if (entry == null) throw StateError('No review thread with id $id.');
    return _threadJson(entry);
  }

  Future<Object?> _add(Map<String, dynamic> args, String? caller) async {
    final path = (args['path'] as String?)?.trim();
    if (path == null || path.isEmpty) {
      throw ArgumentError(
        'path is required: the repository-relative file this comment is about.',
      );
    }
    final comment = args['comment'] as String? ?? '';
    final startLine = (args['startLine'] as num?)?.round();
    final endLine = (args['endLine'] as num?)?.round();
    if (startLine != null && startLine < 1) {
      throw ArgumentError(
        'startLine is 1-based, counted in the file as it is on disk right now.',
      );
    }
    if (endLine != null && startLine == null) {
      throw ArgumentError(
        'endLine without startLine is not a range. Give both, or neither for a '
        'comment about the file as a whole.',
      );
    }
    if (endLine != null && startLine != null && endLine < startLine) {
      throw ArgumentError('endLine cannot come before startLine.');
    }
    final repositoryId = _repositoryFor(args, caller);
    final body =
        reviewBodyOf(comment) ??
        (throw ArgumentError(
          'A review comment needs something written in it.',
        ));
    final sha = (await _anchors.shasFor(repositoryId, [path]))[path];
    if (sha == null) {
      throw StateError(
        'git could not hash `$path` in this repository, so there is nothing to '
        'anchor a comment to. A comment with no anchor could never be checked '
        'against the file later, which is the only thing that makes it worth '
        'keeping.',
      );
    }
    final thread = _context.write(
      ReviewThreadOpen(
        id: _context.newId(),
        repositoryId: repositoryId,
        anchor: ReviewAnchor(
          path: path,
          blobSha: sha,
          startLine: startLine,
          endLine: endLine,
          excerpt: (args['excerpt'] as String?)?.trim(),
        ),
        author: _author(caller),
        authorKind: ReviewAuthorKind.agent,
        body: body,
        sessionId: caller,
      ),
    );
    // `attached` by construction here, and reported anyway: a client that has
    // to remember which calls carry the field forgets on the one that matters.
    return _threadJson(
      AnchoredReviewThread(thread, ReviewThreadAttachment.attached),
    );
  }

  Future<Object?> _reply(Map<String, dynamic> args, String? caller) async {
    final id = _id(args);
    final body =
        reviewBodyOf(args['comment'] as String? ?? '') ??
        (throw ArgumentError('A reply needs something written in it.'));
    _orGone(
      id,
      ReviewThreadReply(
        threadId: id,
        author: _author(caller),
        authorKind: ReviewAuthorKind.agent,
        body: body,
      ),
    );
    return _threadJson((await _anchored(id))!);
  }

  Future<Object?> _status(Map<String, dynamic> args) async {
    final id = _id(args);
    final name = (args['status'] as String?)?.trim();
    if (name == null || !ReviewThreadStatus.settable.contains(name)) {
      throw ArgumentError(
        'status must be one of: ${ReviewThreadStatus.settable.join(', ')}.',
      );
    }
    _orGone(id, ReviewThreadSetStatus(id, ReviewThreadStatus.fromName(name)));
    return _threadJson((await _anchored(id))!);
  }

  /// Writes [request] to thread [id]; a thread that is gone is the app's
  /// words, not the data API's.
  void _orGone(String id, DataRequest<ReviewThread> request) {
    try {
      _context.write(request);
    } on DataRefused catch (refusal) {
      if (refusal.code == DataRefusalCode.notFound) {
        throw StateError('No review thread with id $id.');
      }
      rethrow;
    }
  }

  static String _id(Map<String, dynamic> args) {
    final id = (args['id'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      throw ArgumentError('id is required — review_thread_list has them.');
    }
    return id;
  }

  /// The repository the call is about: the argument, or the caller's own.
  String _repositoryFor(Map<String, dynamic> args, String? caller) {
    final given = (args['repositoryId'] as String?)?.trim();
    if (given != null && given.isNotEmpty) return given;
    final session = caller == null ? null : _sessions.getById(caller);
    if (session == null) {
      throw ArgumentError(
        'No repositoryId, and this caller is not running inside a session, so '
        'there is no checkout to anchor against. Pass repositoryId — '
        'list_checkouts has the ids.',
      );
    }
    return session.repositoryId;
  }

  /// Who a comment is attributed to. Words, not an id: the person reading the
  /// thread in the Changes panel has no way to resolve a key.
  static String _author(String? caller) =>
      caller == null ? 'an agent' : 'an agent in session $caller';

  /// One thread with its anchor checked, or null when it is gone.
  Future<AnchoredReviewThread?> _anchored(String id) async {
    final thread = _threads.getById(id);
    if (thread == null) return null;
    final path = thread.anchor.path;
    final shas = await _anchors.shasFor(thread.repositoryId, [path]);
    return AnchoredReviewThread(
      thread,
      thread.anchor.attachmentAgainst(shas[path]),
    );
  }

  /// Every thread on [repositoryId], each held against the file it points
  /// at, in one git process whatever the count.
  Future<ReviewThreadIndex> _indexFor(String repositoryId) async {
    final threads = _threads.forRepository(repositoryId)
      ..sort(compareReviewThreads);
    if (threads.isEmpty) return ReviewThreadIndex.empty;
    final paths = <String>{for (final thread in threads) thread.anchor.path};
    final shas = await _anchors.shasFor(repositoryId, paths.toList()..sort());
    return ReviewThreadIndex([
      for (final thread in threads)
        AnchoredReviewThread(
          thread,
          thread.anchor.attachmentAgainst(shas[thread.anchor.path]),
        ),
    ]);
  }

  static Set<ReviewThreadStatus>? _statusFilter(Object? raw) {
    final names = switch (raw) {
      final String single when single.trim().isNotEmpty => [single.trim()],
      final List<Object?> many => many.whereType<String>().toList(),
      _ => const <String>[],
    };
    if (names.isEmpty) return null;
    return {for (final name in names) ReviewThreadStatus.fromName(name)};
  }

  static Map<String, Object?> _threadJson(AnchoredReviewThread entry) {
    final thread = entry.thread;
    final anchor = entry.anchor;
    return <String, Object?>{
      'id': thread.id,
      'repositoryId': thread.repositoryId,
      'path': anchor.path,
      // Emitted even when null: an omitted key would read as a gap in the
      // tool rather than as a comment about the whole file.
      'startLine': anchor.startLine,
      'endLine': anchor.endLine,
      'excerpt': anchor.excerpt,
      'status': thread.status.name,
      // The whole reason this feature exists: `detached` means the file
      // changed, so the line numbers above locate nothing, and nothing has
      // guessed.
      'attachment': entry.attachment.name,
      'blobSha': anchor.blobSha,
      'sessionId': thread.sessionId,
      'createdAt': thread.createdAt.toIso8601String(),
      'updatedAt': thread.updatedAt.toIso8601String(),
      'comments': [
        for (final comment in thread.comments)
          <String, Object?>{
            'sequence': comment.sequence,
            'author': comment.author,
            'authorKind': comment.authorKind.name,
            'body': comment.body,
            'createdAt': comment.createdAt.toIso8601String(),
          },
      ],
    };
  }
}

/// The review-thread schemas, as the app served them.
const List<Map<String, Object?>> reviewThreadToolSchemas = [
  {
    'name': 'review_thread_list',
    'description':
        'List the review comment threads on a checkout. Each thread '
        'carries an anchor (a file, optionally a line range), a status, '
        'and every comment made in it. READ THE `attachment` FIELD: '
        '"attached" means the file is byte-for-byte what the comment was '
        'written against, so the line numbers still locate the code; '
        '"detached" means the file has changed since and the line numbers '
        'locate NOTHING — use the excerpt to find what was meant, and do '
        'not assume the code moved by a fixed offset. "unknown" means the '
        'file could not be read at all. Nothing in Karmashala re-anchors a '
        'detached thread by guessing, because a guess that is usually '
        'right cannot be told from one that is wrong.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {
          'type': 'string',
          'description': "Which checkout. Defaults to the calling session's.",
        },
        'path': {
          'type': 'string',
          'description': 'Only threads on this repository-relative file path.',
        },
        'status': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['open', 'shouldFix', 'dismissed', 'resolved'],
          },
          'description':
              'Only threads in these states. Omit for all of them. '
              '"shouldFix" is the set a human has decided must change.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'repositoryId': {'type': 'string'},
        'threads': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['repositoryId', 'threads'],
    },
  },
  {
    'name': 'review_thread_get',
    'description':
        'One review thread by id, with every comment in it and whether it '
        'is still anchored to the file it was written against.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': "The thread's id."},
      },
      'required': ['id'],
    },
  },
  {
    'name': 'review_thread_add',
    'description':
        'Raise a review comment against a file, so a human can triage it '
        'and it survives this conversation. This is where a review '
        'finding belongs — a finding reported only in your transcript is '
        'one nobody can find later, and nobody can answer. Give a line '
        'range when you mean a place in the file, or omit it for a '
        'comment about the file as a whole; line numbers are 1-based and '
        'counted in the file AS IT IS ON DISK RIGHT NOW, which is the '
        'content Karmashala hashes to anchor the thread. It anchors '
        'itself: there is no argument for the hash, and one you supplied '
        'could describe content you read three turns ago. A thread you '
        'raise starts as "open" — a claim awaiting triage — and only a '
        'human moves it to "shouldFix", which is the set that gets sent '
        'back to an author agent. That is deliberate: deciding a change '
        'must be made is the job a human review exists to do.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description':
              'Repository-relative path of the file, as git spells it.',
        },
        'comment': {
          'type': 'string',
          'description':
              'What you found, in the words it should be read in. Stored '
              'exactly as given and never summarised. Say what you '
              'expected and what you saw, not just that something is '
              'wrong.',
        },
        'startLine': {
          'type': 'number',
          'description':
              'First line of the range, 1-based, in the current file. '
              'Omit for a comment about the whole file.',
        },
        'endLine': {
          'type': 'number',
          'description':
              'Last line of the range, inclusive. Defaults to startLine.',
        },
        'excerpt': {
          'type': 'string',
          'description':
              'The code you are commenting on, quoted verbatim. This is '
              'EVIDENCE FOR A HUMAN and is never used to relocate the '
              'comment, so quote what is actually there rather than a '
              'paraphrase — it is what somebody reads when the file has '
              'moved on and the line numbers no longer help.',
        },
        'repositoryId': {
          'type': 'string',
          'description': "Which checkout. Defaults to the calling session's.",
        },
      },
      'required': ['path', 'comment'],
    },
  },
  {
    'name': 'review_thread_reply',
    'description':
        'Answer a review comment in its own thread. Use this to say what '
        'you changed, or to say why you did not — the reply lands beside '
        'the request instead of scrolling past in a different '
        'conversation. Append-only: nothing you write here can be edited '
        'or removed afterwards. Replying does not change the status; '
        'whoever raised the thread decides when it is resolved.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'The thread to reply in.'},
        'comment': {
          'type': 'string',
          'description': 'The reply, stored exactly as given.',
        },
      },
      'required': ['id', 'comment'],
    },
  },
  {
    'name': 'review_thread_status',
    'description':
        'Move a review thread between open, shouldFix, dismissed and '
        'resolved. Nothing written in the thread is touched — the comments '
        'and the anchor stay exactly as they are, and a status can be '
        'moved back, so this is triage rather than a record. "shouldFix" '
        'is the set the Changes panel hands to an author agent, so putting '
        'a thread there is asking for the change to be made; "dismissed" '
        'keeps the thread and the fact that somebody looked at it, which '
        'is why there is no way to delete one.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'The thread to move.'},
        'status': {
          'type': 'string',
          'enum': ['open', 'shouldFix', 'dismissed', 'resolved'],
          'description': 'Where to move it.',
        },
      },
      'required': ['id', 'status'],
    },
  },
];
