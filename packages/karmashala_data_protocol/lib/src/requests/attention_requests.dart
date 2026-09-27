part of '../data_request.dart';

// Session status and attention (slice 5c). The server keeps every watched
// session's status and the inbox, and decides what needs a person; a client
// is told (`SessionStatusChanged`, `InboxChanged`, `AttentionNews`) and asks
// here. Everything is in the server's memory, so each is answered at once.
// `checks.run` runs commands, so it is answered when done.
//
// Refusals: `notFound` for an inbox item that is not there (or no longer),
// `invalid` for arguments out of shape, `unavailable` from a server that
// keeps no attention (no store).

DataRequest<Object?>? _attentionRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      StatusList.name => const StatusList(),
      InboxList.name => const InboxList(),
      InboxDismiss.name => InboxDismiss(args.string('id')),
      InboxOpen.name => InboxOpen(args.string('id')),
      InboxSeen.name => InboxSeen(args.strings('openIds', orEmpty: true)),
      InboxMarkAllSeen.name => const InboxMarkAllSeen(),
      InboxRaise.name => InboxRaise(args.value('item', InboxItem.fromJson)),
      ChecksRun.name => ChecksRun(args.string('sessionId')),
      _ => null,
    };

/// Status and the attention inbox, kept by the server; answered at once.
sealed class AttentionRequest<R> extends DataRequest<R> {
  const AttentionRequest();
}

/// Every session's status the server keeps now, and its last cycle's reach.
/// A subscriber is also greeted with them.
final class StatusList extends AttentionRequest<StatusSnapshot> {
  const StatusList();

  static const String name = 'status.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(StatusSnapshot result) => result.toJson();

  @override
  StatusSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => StatusSnapshot.fromJson(_object(json, kind)));
}

/// The inbox and who is waiting now. A subscriber is also greeted with it.
final class InboxList extends AttentionRequest<AttentionSnapshot> {
  const InboxList();

  static const String name = 'inbox.list';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(AttentionSnapshot result) => result.toJson();

  @override
  AttentionSnapshot resultFromJson(Object? json) =>
      _decode(kind, () => AttentionSnapshot.fromJson(_object(json, kind)));
}

/// Takes item [id] off the inbox for good (a follow-up is resolved in its
/// table too). A condition that still holds comes back on the next cycle.
final class InboxDismiss extends AttentionRequest<DataAck> {
  const InboxDismiss(this.id);

  static const String name = 'inbox.dismiss';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Opens item [id]: marks it seen at the server (an event leaves, a question
/// stays) and tells every window to show its session
/// ([InboxOpenWanted]) — the asking window by this answer.
final class InboxOpen extends AttentionRequest<InboxOpened> {
  const InboxOpen(this.id);

  static const String name = 'inbox.open';

  final String id;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id};

  @override
  Object? resultToJson(InboxOpened result) => result.toJson();

  @override
  InboxOpened resultFromJson(Object? json) =>
      _decode(kind, () => InboxOpened.fromJson(_object(json, kind)));
}

/// What this window is looking at now — the sessions it shows while it has
/// focus; empty when it has none, or shows none. The server keeps it per
/// link and marks every item about them seen, now and as they arrive, until
/// the window says otherwise or goes.
final class InboxSeen extends AttentionRequest<DataAck> {
  const InboxSeen(this.openIds);

  static const String name = 'inbox.seen';

  final List<String> openIds;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'openIds': openIds};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// "I have read the inbox": events leave, anything else stays, seen.
final class InboxMarkAllSeen extends AttentionRequest<DataAck> {
  const InboxMarkAllSeen();

  static const String name = 'inbox.markAllSeen';

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Files [item], or replaces the one with its id — what a client's own
/// watcher saw that the server does not watch yet (a usage limit).
final class InboxRaise extends AttentionRequest<DataAck> {
  const InboxRaise(this.item);

  static const String name = 'inbox.raise';

  final InboxItem item;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'item': item.toJson()};

  @override
  Object? resultToJson(DataAck result) => null;

  @override
  DataAck resultFromJson(Object? json) => const DataAck();
}

/// Session work that runs commands; answered when done.
sealed class ChecksWorkRequest<R> extends DataRequest<R> {
  const ChecksWorkRequest();
}

/// Runs session [sessionId]'s checkout's project checks at the server — in
/// sessions it owns on its own machine (WSL too, on Windows), as commands
/// over its own connection on an SSH box — as one verification run.
final class ChecksRun extends ChecksWorkRequest<SessionChecksRun> {
  const ChecksRun(this.sessionId);

  static const String name = 'checks.run';

  final String sessionId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'sessionId': sessionId};

  @override
  Object? resultToJson(SessionChecksRun result) => result.toJson();

  @override
  SessionChecksRun resultFromJson(Object? json) =>
      _decode(kind, () => SessionChecksRun.fromJson(_object(json, kind)));
}
