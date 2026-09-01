import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/agent_descriptor.dart';
import 'antigravity_store_reader.dart';

/// How far before a session was launched a conversation may have been written
/// and still count as the one that session started.
///
/// The same defence `kAdoptionMtimeSlack` is in `SessionAdoptionService`, and
/// tighter in effect than the number suggests: `agy` creates the conversation
/// file on the **first turn**, which is after the launch, not around it. The
/// window exists for clock skew between a WSL filesystem and the Windows host
/// reading it, not because the file might legitimately predate the launch.
const Duration kAntigravityAttributionSlack = Duration(seconds: 10);

/// Where a conversation id came from, in descending order of authority.
enum AntigravityIdSource {
  /// The CLI printed it. Not a heuristic: the agent stated, in our own pane,
  /// which conversation it was on.
  announcement,

  /// `cache/last_conversations.json` named it for the directory we launched in,
  /// and the guards in [AntigravitySessionAttributor] agreed it is ours.
  lastConversation,
}

/// What was learned about which conversation a session is on.
///
/// A refusal carries [reason] in plain words rather than being empty, because
/// "no CLI session id found" is exactly the message the owner hit and it says
/// nothing about which of the several different situations they are in.
class AntigravityIdAttribution {
  const AntigravityIdAttribution.learned(String id, AntigravityIdSource from)
    : conversationId = id,
      source = from,
      reason = '';

  const AntigravityIdAttribution.none(this.reason)
    : conversationId = null,
      source = null;

  final String? conversationId;
  final AntigravityIdSource? source;

  /// Why nothing was learned. Empty when something was.
  final String reason;

  bool get isLearned => conversationId != null;

  @override
  String toString() => isLearned
      ? 'AntigravityIdAttribution($conversationId via ${source!.name})'
      : 'AntigravityIdAttribution(none: $reason)';
}

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
  Future<AntigravityIdAttribution> attribute({
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
      return AntigravityIdAttribution.learned(
        announced,
        AntigravityIdSource.announcement,
      );
    }

    final byDirectory = await reader.readLastConversations(storeHome);
    final entry = conversationForDirectory(byDirectory, workingDirectory);
    if (entry == null) {
      return AntigravityIdAttribution.none(
        'Antigravity has recorded no conversation for $workingDirectory. It '
        'writes one only after the first message, so a session that was never '
        'prompted has none to find.',
      );
    }

    if (conversationIdsHeldByOtherSessions.contains(entry)) {
      return AntigravityIdAttribution.none(
        'The conversation Antigravity records for $workingDirectory already '
        'belongs to another session here, so it is not this one.',
      );
    }

    if (directoryHeldBefore != null) {
      return entry == directoryHeldBefore
          ? AntigravityIdAttribution.none(
              'Antigravity has not started a new conversation in '
              '$workingDirectory since this session was launched; the one '
              'recorded there was already open beforehand.',
            )
          : AntigravityIdAttribution.learned(
              entry,
              AntigravityIdSource.lastConversation,
            );
    }

    final modified = await _modifiedAt(storeHome, entry);
    if (modified == null) {
      return AntigravityIdAttribution.none(
        'Antigravity records conversation $entry for $workingDirectory, but '
        'its file could not be read, so there is no way to tell whether it is '
        'this session or an earlier one.',
      );
    }
    if (modified.isBefore(launchedAt.subtract(mtimeSlack))) {
      return AntigravityIdAttribution.none(
        'The conversation Antigravity records for $workingDirectory was last '
        'written before this session started, so it belongs to an earlier one.',
      );
    }
    return AntigravityIdAttribution.learned(
      entry,
      AntigravityIdSource.lastConversation,
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
  return null;
}

String _trimSeparators(String path) {
  var end = path.length;
  while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
    end--;
  }
  return path.substring(0, end);
}

/// What to put on an `agy` command line to continue an existing session.
sealed class AntigravityResumePlan {
  const AntigravityResumePlan();

  /// The arguments this plan contributes. Empty for a refusal.
  List<String> get arguments;
}

/// The conversation is known and named outright.
final class AntigravityResumeById extends AntigravityResumePlan {
  const AntigravityResumeById(this.conversationId, this.arguments);

  final String conversationId;

  @override
  final List<String> arguments;
}

/// No id was learned, but the store names exactly one conversation for this
/// directory and `--continue` would reopen it.
///
/// [conversationId] is what would be continued — carried so the app can *say*
/// it rather than offering a blind "continue whatever was last". That is the
/// whole difference between this and a recency picker.
final class AntigravityContinueLatest extends AntigravityResumePlan {
  const AntigravityContinueLatest({
    required this.conversationId,
    required this.arguments,
  });

  final String conversationId;

  @override
  final List<String> arguments;
}

/// Nothing truthful can be put on the command line. [reason] is shown.
final class AntigravityResumeRefused extends AntigravityResumePlan {
  const AntigravityResumeRefused(this.reason);

  final String reason;

  @override
  List<String> get arguments => const [];
}

/// How to continue an Antigravity session, given what is known about it.
///
/// The refusal the owner hit — "No resumable CLI session id could be found" —
/// is the last of four answers here, not the first. An id resumes exactly; a
/// directory whose conversation the store names continues by name; a
/// conversation another session already holds refuses *because of that*, which
/// is a different situation and deserves different words.
AntigravityResumePlan planAntigravityResume({
  required AgentDescriptor descriptor,
  required String workingDirectory,
  String? conversationId,
  String? lastConversationForDirectory,
  Set<String> conversationIdsHeldByOtherSessions = const {},
}) {
  final id = conversationId?.trim();
  if (id != null && id.isNotEmpty) {
    return AntigravityResumeById(
      id,
      descriptor.launch.interactiveResume.argumentsFor(id),
    );
  }

  final continueLatest = descriptor.launch.continueLatest;
  if (!continueLatest.isSupported) {
    return AntigravityResumeRefused(
      'This session has no Antigravity conversation id recorded, and '
      '${descriptor.displayName} cannot be told to continue without one.',
    );
  }

  final latest = lastConversationForDirectory?.trim();
  if (latest == null || latest.isEmpty) {
    return AntigravityResumeRefused(
      'This session has no Antigravity conversation id recorded, and '
      'Antigravity has no conversation for $workingDirectory to continue '
      'instead.',
    );
  }

  if (conversationIdsHeldByOtherSessions.contains(latest)) {
    return AntigravityResumeRefused(
      'This session has no Antigravity conversation id recorded. Continuing '
      'would reopen $latest, which another session here already holds, so it '
      'is refused rather than opening a second writer on it.',
    );
  }

  return AntigravityContinueLatest(
    conversationId: latest,
    arguments: continueLatest.arguments,
  );
}
