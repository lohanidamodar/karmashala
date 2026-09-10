import 'package:agent_cli/read.dart';
import 'session.dart';
import 'session_launch.dart';

/// How long after a launch a row is left alone, whatever the store says: Claude
/// Code writes its transcript when something is *said*, not when it starts.
const Duration kUnkeptPromiseGrace = Duration(minutes: 5);

/// Why a row is, or is not, worth asking the CLI store about. Kept apart rather
/// than folded into a bool: "running" and "invisible" would both read as "fine".
enum PromiseScreening {
  /// The row named a conversation of our own minting, nothing of ours is
  /// running it, and it is old enough to judge. Ask the store.
  candidate,

  /// The row never made the promise: no external id, an id the CLI chose for
  /// itself, or an agent that cannot be handed one. Nothing here is broken.
  neverPromised,

  /// Its worktree was archived away. Tidying is already recorded for this row.
  archived,

  /// A pane of ours is running it **right now** — certain knowledge, and the
  /// one answer that outranks anything a store could say.
  hostedLive,

  /// Launched into a terminal we do not own, so a dead promise and a pending
  /// one look alike. Deliberately excluded rather than guessed at.
  external,

  /// Started inside [kUnkeptPromiseGrace]. Too young to judge.
  tooNew,
}

/// Whether [session] is worth asking a CLI store about — from the row and two
/// in-memory facts, with **no disk and no subprocess**, because this runs per row.
PromiseScreening screenSessionPromise(
  Session session, {
  required bool agentAssignsSessionId,
  required bool hostedLive,
  required DateTime now,
  Duration grace = kUnkeptPromiseGrace,
}) {
  // Certain, and first: we own the process and can see it. A row we are running
  // must never be offered for deletion, whatever a store scan makes of it.
  if (hostedLive) return PromiseScreening.hostedLive;
  if (session.isArchived) return PromiseScreening.archived;
  if (!promisedItsOwnConversation(
    session,
    agentAssignsSessionId: agentAssignsSessionId,
  )) {
    return PromiseScreening.neverPromised;
  }
  if (session.surface == SessionSurface.external) {
    return PromiseScreening.external;
  }
  if (now.difference(session.createdAt) < grace) {
    return PromiseScreening.tooNew;
  }
  return PromiseScreening.candidate;
}

/// Whether this row's `externalSessionId` is a promise **we** made. The test is
/// `externalSessionId == id`, not `!= null`: nullability cannot tell them apart.
bool promisedItsOwnConversation(
  Session session, {
  required bool agentAssignsSessionId,
}) {
  final external = session.externalSessionId;
  return agentAssignsSessionId &&
      external != null &&
      external.isNotEmpty &&
      external == session.id;
}

/// What we can say about one candidate row after the store was swept. Three
/// answers, off [ConversationPresence] so the vocabulary stays the resume's.
enum PromiseVerdict {
  /// The store holds the conversation. The promise was kept; the row is fine.
  kept,

  /// The store was read **completely** and does not hold it. The only verdict
  /// strong enough to offer a row for deletion.
  unkept,

  /// We could not tell — an unreachable store, a format nobody reads, a listing
  /// that failed part way. A row here is reported and left alone.
  unknown;

  static PromiseVerdict of(ConversationPresence presence) => switch (presence) {
    ConversationPresence.present => PromiseVerdict.kept,
    ConversationPresence.absent => PromiseVerdict.unkept,
    ConversationPresence.unknown => PromiseVerdict.unknown,
  };

  /// Whether a row with this verdict may be removed without asking anything
  /// else. Only [unkept] — see [ConversationPresence.absent].
  bool get isRemovable => this == PromiseVerdict.unkept;
}

/// The one clause a reviewed row is labelled with.
String promiseVerdictNote(PromiseVerdict verdict, String agentName) =>
    switch (verdict) {
      PromiseVerdict.kept => '$agentName has this conversation',
      PromiseVerdict.unkept => 'no conversation in $agentName\'s store',
      PromiseVerdict.unknown => 'could not check — left alone',
    };

/// The sentence above a review, saying what the reading covers and what it does
/// not — a stopped WSL distribution leaves rows unjudged, not silently kept.
String unkeptPromiseSummary({
  required int removable,
  required int uncertain,
  required int storesRead,
}) {
  if (storesRead == 0) {
    return 'No CLI store could be read, so nothing here has been checked. '
        'Nothing will be removed.';
  }
  final head = switch (removable) {
    0 => 'No session names a conversation its agent has lost.',
    1 => '1 session names a conversation its agent does not have.',
    _ => '$removable sessions name conversations their agents do not have.',
  };
  if (uncertain == 0) return head;
  final tail = uncertain == 1
      ? '1 more could not be checked and is left alone.'
      : '$uncertain more could not be checked and are left alone.';
  return '$head $tail';
}

/// The plain words for restarting a row instead of deleting it: the row keeps
/// its title, age and lineage, and its promise is made again to a live CLI.
String restartUnkeptPromiseMessage(String title) =>
    'Started a new conversation in "$title". The session keeps its title and '
    'history in Karmashala; only the agent conversation is new.';
