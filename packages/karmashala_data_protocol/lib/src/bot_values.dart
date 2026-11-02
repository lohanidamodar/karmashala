import 'package:karmashala_session/session.dart';

/// One agent the bot can run on: an agent with a chat form on the server's own
/// machine.
final class BotAgent {
  const BotAgent({
    required this.agentId,
    required this.name,
    required this.installationId,
  });

  /// The agent's chat-form id, as `bot.agent.set` takes it.
  final String agentId;

  /// Its display name.
  final String name;
  final String installationId;

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'name': name,
    'installationId': installationId,
  };

  static BotAgent fromJson(Map<String, Object?> json) => BotAgent(
    agentId: json['agentId']! as String,
    name: json['name']! as String,
    installationId: json['installationId']! as String,
  );
}

/// The bot as a client needs it: `bot.state`, `bot.subscribe` and `bot.open`
/// all answer this.
final class BotState {
  const BotState({
    this.session,
    this.agents = const [],
    this.agentId,
    this.agentSetting,
    this.notice,
    this.approvals = const [],
  });

  /// The bot's row, a client's only way to it. Null before the first message
  /// and after a clear: the panel shows its empty state, and `bot.open` makes
  /// the row.
  final Session? session;

  /// What the switcher and the setting list. Empty means no agent with a chat
  /// form is installed on the server: the panel explains and links to Agents.
  final List<BotAgent> agents;

  /// The agent the bot runs on, or would start on. Null when [agents] is empty.
  final String? agentId;

  /// The setting: null is "Default agent".
  final String? agentSetting;

  /// A plain reason to show, e.g. the default agent has no chat form and
  /// another stands in for it.
  final String? notice;

  /// What waits for a person's Yes or No, oldest first.
  final List<BotApproval> approvals;

  Map<String, Object?> toJson() => {
    if (session case final row?) 'session': row.toJson(),
    'agents': [for (final agent in agents) agent.toJson()],
    'agentId': ?agentId,
    'agentSetting': ?agentSetting,
    'notice': ?notice,
    'approvals': [for (final approval in approvals) approval.toJson()],
  };

  static BotState fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> rows(String key) => [
      for (final row in json[key] as List? ?? const [])
        (row as Map).cast<String, Object?>(),
    ];
    final session = json['session'];
    return BotState(
      session: session is Map
          ? Session.fromJson(session.cast<String, Object?>())
          : null,
      agents: [for (final row in rows('agents')) BotAgent.fromJson(row)],
      agentId: json['agentId'] as String?,
      agentSetting: json['agentSetting'] as String?,
      notice: json['notice'] as String?,
      approvals: [
        for (final row in rows('approvals')) BotApproval.fromJson(row),
      ],
    );
  }
}
