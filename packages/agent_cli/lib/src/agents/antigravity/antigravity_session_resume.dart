import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/agent_descriptor.dart';
import '../adapter/directory_conversation_attribution.dart';
import '../adapter/directory_resume_plan.dart';
import './antigravity_store_reader.dart';

/// How far before a session was launched a conversation may have been written
/// and still count as the one that session started.
///
/// The same defence `kAdoptionMtimeSlack` is in `SessionAdoptionService`, and
/// tighter in effect than the number suggests: `agy` creates the conversation
/// file on the **first turn**, which is after the launch, not around it. The
/// window exists for clock skew between a WSL filesystem and the Windows host
/// reading it, not because the file might legitimately predate the launch.
const Duration kAntigravityAttributionSlack = Duration(seconds: 10);

/// Works out which Antigravity conversation a session we launched is on.
///
/// `agy` mints its own conversation id and will not accept one, so unlike
/// Claude Code the id cannot be pinned at launch, and unlike Codex the store
/// cannot be scanned for it — every conversation file looks alike from outside
/// and the one we want is distinguished only by *when* and *where* it was made.
///
/// Two signals answer that, and the order matters because the failure being
/// guarded against is resuming somebody else's conversation:
///
/// 1. **What the CLI said.** `agy` prints `agy --conversation=<id>` as it
///    exits. A line the agent printed in our own pane is not an inference about
///    which conversation it was, so it wins outright and needs no guards.
/// 2. **What the store recorded for the directory.**
///    `cache/last_conversations.json` maps each directory to the conversation
///    last used there. A directory is a much narrower claim than recency alone
///    — it is the same key `agy -c` resolves through — but it is still an
///    inference, so it is only believed when it is *new*: either the entry
///    changed since we snapshotted it at launch, or the conversation file it
///    names was written after the launch.
///
/// Anything else refuses, in words. Continuing on a hunch is the one outcome
/// worse than saying nothing was learned.
class AntigravitySessionAttributor {
  const AntigravitySessionAttributor({
    this.reader = const AntigravityStoreReader(countSteps: false),
    this.mtimeSlack = kAntigravityAttributionSlack,
  });

  final AntigravityStoreReader reader;
  final Duration mtimeSlack;

  /// The conversation the session launched in [workingDirectory] at
  /// [launchedAt] is on.
  ///
  /// [paneOutput] is whatever of the pane's own scrollback the caller has —
  /// empty is fine, it simply drops the strongest signal.
  ///
  /// [directoryHeldBefore] is the conversation this directory named *before*
  /// the session was launched, when the caller thought to look. It is the
  /// sharpest guard available: an entry that changed can only have been written
  /// by the process we started. Without it the file's mtime is used instead,
  /// which is weaker because a conversation touched moments before our launch
  /// passes it.
  ///
  /// [conversationIdsHeldByOtherSessions] is the app's existing idempotence
  /// rule, borrowed from `SessionAdoptionService`: a conversation another
  /// session row already holds is never attributed to a second one.
  Future<DirectoryConversationAttribution> attribute({
    required AgentDescriptor descriptor,
    required String storeHome,
    required String workingDirectory,
    required DateTime launchedAt,
    String paneOutput = '',
    String? directoryHeldBefore,
    Set<String> conversationIdsHeldByOtherSessions = const {},
  }) async {
    final announced = descriptor.launch.sessionIdAnnouncement.idIn(paneOutput);
    if (announced != null) {
      return DirectoryConversationAttribution.learned(
        announced,
        DirectoryConversationSource.announcement,
      );
    }

    final byDirectory = await reader.readLastConversations(storeHome);
    final entry = conversationForDirectory(byDirectory, workingDirectory);
    if (entry == null) {
      return DirectoryConversationAttribution.none(
        'Antigravity has recorded no conversation for $workingDirectory. It '
        'writes one only after the first message, so a session that was never '
        'prompted has none to find.',
      );
    }

    if (conversationIdsHeldByOtherSessions.contains(entry)) {
      return DirectoryConversationAttribution.none(
        'The conversation Antigravity records for $workingDirectory already '
        'belongs to another session here, so it is not this one.',
      );
    }

    if (directoryHeldBefore != null) {
      return entry == directoryHeldBefore
          ? DirectoryConversationAttribution.none(
              'Antigravity has not started a new conversation in '
              '$workingDirectory since this session was launched; the one '
              'recorded there was already open beforehand.',
            )
          : DirectoryConversationAttribution.learned(
              entry,
              DirectoryConversationSource.lastConversation,
            );
    }

    final modified = await _modifiedAt(storeHome, entry);
    if (modified == null) {
      return DirectoryConversationAttribution.none(
        'Antigravity records conversation $entry for $workingDirectory, but '
        'its file could not be read, so there is no way to tell whether it is '
        'this session or an earlier one.',
      );
    }
    if (modified.isBefore(launchedAt.subtract(mtimeSlack))) {
      return DirectoryConversationAttribution.none(
        'The conversation Antigravity records for $workingDirectory was last '
        'written before this session started, so it belongs to an earlier one.',
      );
    }
    return DirectoryConversationAttribution.learned(
      entry,
      DirectoryConversationSource.lastConversation,
    );
  }

  Future<DateTime?> _modifiedAt(String storeHome, String id) async {
    try {
      final stat = await File(
        p.join(storeHome, 'conversations', '$id.db'),
      ).stat();
      return stat.type == FileSystemEntityType.notFound ? null : stat.modified;
    } on FileSystemException {
      return null;
    }
  }
}

/// The conversation [byDirectory] records for [directory], or `null`.
///
/// Directories are compared after trailing separators are stripped and nothing
/// else. **No case folding**: these are the paths `agy` was launched in, which
/// on the only platform it is installed on here are POSIX and case-sensitive,
/// and folding would let `/work` match `/Work` — two different directories, and
/// the cost of matching them is resuming a stranger's conversation.
String? conversationForDirectory(
  Map<String, String> byDirectory,
  String directory,
) {
  final wanted = _trimSeparators(directory);
  if (wanted.isEmpty) return null;
  for (final entry in byDirectory.entries) {
    if (_trimSeparators(entry.key) == wanted) return entry.value;
  }
  final normWanted = _normalizePathForMatch(wanted);
  for (final entry in byDirectory.entries) {
    final normEntry = _normalizePathForMatch(_trimSeparators(entry.key));
    if (normWanted == normEntry) return entry.value;
  }
  return null;
}

String _normalizePathForMatch(String path) {
  var p = path.replaceAll(r'\', '/');
  final m = RegExp(r'^/mnt/([a-zA-Z])/(.*)$').firstMatch(p);
  if (m != null) {
    p = '${m.group(1)}:/${m.group(2)}';
  }
  if (RegExp(r'^[a-zA-Z]:/').hasMatch(p)) {
    return p.toLowerCase();
  }
  return p;
}

String _trimSeparators(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}

/// How to continue an Antigravity session, given what is known about it.
///
/// The refusal the owner hit — "No resumable CLI session id could be found" —
/// is the last of four answers here, not the first. An id resumes exactly; a
/// directory whose conversation the store names continues by name; a
/// conversation another session already holds refuses *because of that*, which
/// is a different situation and deserves different words.
DirectoryResumePlan planAntigravityResume({
  required AgentDescriptor descriptor,
  required String workingDirectory,
  String? conversationId,
  String? lastConversationForDirectory,
  Set<String> conversationIdsHeldByOtherSessions = const {},
}) {
  final id = conversationId?.trim();
  if (id != null && id.isNotEmpty) {
    return DirectoryResumeById(
      id,
      descriptor.launch.interactiveResume.argumentsFor(id),
    );
  }

  final continueLatest = descriptor.launch.continueLatest;
  if (!continueLatest.isSupported) {
    return DirectoryResumeRefused(
      'This session has no Antigravity conversation id recorded, and '
      '${descriptor.displayName} cannot be told to continue without one.',
    );
  }

  final latest = lastConversationForDirectory?.trim();
  if (latest == null || latest.isEmpty) {
    return DirectoryResumeRefused(
      'This session has no Antigravity conversation id recorded, and '
      'Antigravity has no conversation for $workingDirectory to continue '
      'instead.',
    );
  }

  if (conversationIdsHeldByOtherSessions.contains(latest)) {
    return DirectoryResumeRefused(
      'This session has no Antigravity conversation id recorded. Continuing '
      'would reopen $latest, which another session here already holds, so it '
      'is refused rather than opening a second writer on it.',
    );
  }

  return DirectoryContinueLatest(
    conversationId: latest,
    // By name, not by `--continue` — see [DirectoryContinueLatest].
    arguments: descriptor.launch.interactiveResume.argumentsFor(latest),
  );
}
