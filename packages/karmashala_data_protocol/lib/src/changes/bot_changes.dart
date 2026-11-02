part of '../data_change.dart';

// The bot, told only to a client that asked (`bot.subscribe`): every other
// client is told nothing of it. Its row never travels as `sessionRowChanged`,
// which is what keeps it out of every list.

DataChange? _botChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'botRowChanged' => BotRowChanged(Session.fromJson(_row(json))),
      'botApprovalChanged' => BotApprovalChanged(
        BotApproval.fromJson(_row(json)),
      ),
      'botAgentChanged' => BotAgentChanged(
        agentId: json['agentId'] as String?,
        agentSetting: json['agentSetting'] as String?,
        notice: json['notice'] as String?,
      ),
      _ => null,
    };

/// The bot's row as it now stands. One [Session.isArchived] was cleared: the
/// panel goes back to its empty state.
final class BotRowChanged extends DataChange {
  const BotRowChanged(this.row);

  final Session row;

  @override
  Map<String, Object?> toJson() => {
    'change': 'botRowChanged',
    'row': row.toJson(),
  };
}

/// A request for approval as it now stands, once on arrival and once each
/// time it moves.
final class BotApprovalChanged extends DataChange {
  const BotApprovalChanged(this.approval);

  final BotApproval approval;

  @override
  Map<String, Object?> toJson() => {
    'change': 'botApprovalChanged',
    'row': approval.toJson(),
  };
}

/// The bot's agent, its setting, and any reason to show, as they now stand.
final class BotAgentChanged extends DataChange {
  const BotAgentChanged({this.agentId, this.agentSetting, this.notice});

  final String? agentId;
  final String? agentSetting;
  final String? notice;

  @override
  Map<String, Object?> toJson() => {
    'change': 'botAgentChanged',
    'agentId': ?agentId,
    'agentSetting': ?agentSetting,
    'notice': ?notice,
  };
}
