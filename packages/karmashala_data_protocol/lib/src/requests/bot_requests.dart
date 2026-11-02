part of '../data_request.dart';

// The server's bot: one lasting conversation, hidden from every list. These
// are a client's only way to its row. The conversation itself is an ordinary
// session's: `sessions.send`, `sessions.transcript`, `sessions.queue.*`,
// `sessions.interrupt`, `sessions.setMode`, named by `BotState.session.id`.
// See PROJECT.md §26 for the whole contract. An older server has none of
// this: a client reads [BotOpen.feature] in `welcome.features` first.

DataRequest<Object?>? _botRequestFromJson(String kind, _Arguments args) =>
    switch (kind) {
      BotStateRead.name => const BotStateRead(),
      BotSubscribe.name => const BotSubscribe(),
      BotOpen.name => const BotOpen(),
      BotClear.name => const BotClear(),
      BotAgentSet.name => BotAgentSet(args.optionalString('agentId')),
      BotApprovalAnswer.name => BotApprovalAnswer(
        args.string('id'),
        approve: args.boolean('approve'),
      ),
      _ => null,
    };

/// A request of the bot, answered when its work is done.
sealed class BotRequest<R> extends DataRequest<R> {
  const BotRequest();
}

/// One that answers the bot as it now stands.
sealed class _BotStateRequest extends BotRequest<BotState> {
  const _BotStateRequest();

  @override
  Map<String, Object?> argumentsToJson() => const {};

  @override
  Object? resultToJson(BotState result) => result.toJson();

  @override
  BotState resultFromJson(Object? json) =>
      _decode(kind, () => BotState.fromJson(_object(json, kind)));
}

/// The bot as it stands. Creates nothing.
final class BotStateRead extends _BotStateRequest {
  const BotStateRead();

  static const String name = 'bot.state';

  @override
  String get kind => name;
}

/// [BotStateRead], and from now on this client is told of the bot: its row
/// ([BotRowChanged]), its agent ([BotAgentChanged]), its approvals
/// ([BotApprovalChanged]), its status, queue and inbox items. A client that
/// never asks is told nothing of it, which is how an older client stays
/// unaware. Asked again after a reconnect: a link follows only while it lives.
final class BotSubscribe extends _BotStateRequest {
  const BotSubscribe();

  static const String name = 'bot.subscribe';

  @override
  String get kind => name;
}

/// Returns the bot's row, making it first when there is none: what a client
/// calls as the person sends their first message, then `sessions.send`. Makes
/// the hidden project on the way. Refused `unavailable` with no chat agent.
final class BotOpen extends _BotStateRequest {
  const BotOpen();

  static const String name = 'bot.open';

  /// In `welcome.features` when the server has a bot.
  static const String feature = 'bot';

  @override
  String get kind => name;
}

/// Clears the conversation: detaches every session the bot started, expires
/// what waits for approval, ends and archives the row. `MEMORY.md` is kept,
/// and the next [BotOpen] makes a new row. Refused `conflict` while a turn
/// runs. The client asks the person first.
final class BotClear extends _BotStateRequest {
  const BotClear();

  static const String name = 'bot.clear';

  @override
  String get kind => name;
}

/// Saves the agent the bot runs on, null for "Default agent", and switches a
/// row that exists to it in place: the same chat, carried over as
/// `sessions.switchAgent` carries it. Refused `conflict` mid-turn with nothing
/// saved, and `invalid` for an agent with no chat form on the server.
final class BotAgentSet extends _BotStateRequest {
  const BotAgentSet(this.agentId);

  static const String name = 'bot.agent.set';

  final String? agentId;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'agentId': ?agentId};
}

/// A person's Yes or No to what the bot asked. Yes consumes the request and
/// the server runs the recorded call itself, once; the answer does not wait
/// for it. Refused `conflict` when it was already answered or has expired.
final class BotApprovalAnswer extends BotRequest<BotApproval> {
  const BotApprovalAnswer(this.id, {required this.approve});

  static const String name = 'bot.approval.answer';

  final String id;
  final bool approve;

  @override
  String get kind => name;

  @override
  Map<String, Object?> argumentsToJson() => {'id': id, 'approve': approve};

  @override
  Object? resultToJson(BotApproval result) => result.toJson();

  @override
  BotApproval resultFromJson(Object? json) =>
      _decode(kind, () => BotApproval.fromJson(_object(json, kind)));
}
