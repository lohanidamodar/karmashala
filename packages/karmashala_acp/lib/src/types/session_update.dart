import 'package:meta/meta.dart';

import '../json.dart';
import 'content_block.dart';
import 'enums.dart';
import 'plan.dart';
import 'session_config.dart';
import 'tool_call.dart';

/// A `session/update` notification: which session, and what changed.
@immutable
final class SessionUpdateEvent {
  const SessionUpdateEvent(this.sessionId, this.update);

  factory SessionUpdateEvent.fromJson(JsonMap params) => SessionUpdateEvent(
    params.string('sessionId') ?? '',
    SessionUpdate.fromJson(params.object('update') ?? const {}),
  );

  final String sessionId;
  final SessionUpdate update;

  JsonMap toJson() => {'sessionId': sessionId, 'update': update.toJson()};
}

/// What an agent reports during a turn. A `sessionUpdate` kind this package
/// has no class for parses as [UnknownUpdate] and is never dropped.
@immutable
sealed class SessionUpdate {
  const SessionUpdate();

  factory SessionUpdate.fromJson(JsonMap json) {
    final kind = json.string('sessionUpdate');
    return switch (kind) {
      'user_message_chunk' => UserMessageChunk(
        _content(json),
        messageId: json.string('messageId'),
      ),
      'agent_message_chunk' => AgentMessageChunk(
        _content(json),
        messageId: json.string('messageId'),
      ),
      'agent_thought_chunk' => AgentThoughtChunk(
        _content(json),
        messageId: json.string('messageId'),
      ),
      'tool_call' => ToolCallUpdate.fromJson(json, isNew: true),
      'tool_call_update' => ToolCallUpdate.fromJson(json, isNew: false),
      'plan' => PlanUpdate([
        for (final entry in json.objects('entries') ?? const <JsonMap>[])
          PlanEntry.fromJson(entry),
      ]),
      'available_commands_update' => AvailableCommandsUpdate([
        for (final c in json.objects('availableCommands') ?? const <JsonMap>[])
          AvailableCommand.fromJson(c),
      ]),
      'current_mode_update' => CurrentModeUpdate(
        json.string('currentModeId') ?? '',
      ),
      'config_option_update' => ConfigOptionUpdate(
        configOptionsFromJson(json.objects('configOptions')) ?? const [],
      ),
      'session_info_update' => SessionInfoUpdate(
        title: json.string('title'),
        updatedAt: json.string('updatedAt'),
      ),
      'usage_update' => UsageUpdate(
        used: json.integer('used') ?? 0,
        size: json.integer('size') ?? 0,
        cost: switch (json.object('cost')) {
          final cost? => UsageCost.fromJson(cost),
          null => null,
        },
      ),
      _ => UnknownUpdate(kind ?? '', json),
    };
  }

  static ContentBlock _content(JsonMap json) =>
      ContentBlock.fromJson(json.object('content') ?? const {});

  /// The wire `sessionUpdate` value.
  String get sessionUpdate;

  JsonMap toJson();
}

/// A chunk of a message; the three chunk kinds differ only in who speaks.
sealed class MessageChunk extends SessionUpdate {
  const MessageChunk(this.content, {this.messageId});

  final ContentBlock content;

  /// Groups chunks of one message, when the agent numbers them.
  final String? messageId;

  @override
  JsonMap toJson() => withoutNulls({
    'sessionUpdate': sessionUpdate,
    'content': content.toJson(),
    'messageId': messageId,
  });
}

final class UserMessageChunk extends MessageChunk {
  const UserMessageChunk(super.content, {super.messageId});

  @override
  String get sessionUpdate => 'user_message_chunk';
}

final class AgentMessageChunk extends MessageChunk {
  const AgentMessageChunk(super.content, {super.messageId});

  @override
  String get sessionUpdate => 'agent_message_chunk';
}

final class AgentThoughtChunk extends MessageChunk {
  const AgentThoughtChunk(super.content, {super.messageId});

  @override
  String get sessionUpdate => 'agent_thought_chunk';
}

/// A tool call starting ([isNew]) or changing. Every field but the id is
/// optional on an update, where it means "unchanged".
final class ToolCallUpdate extends SessionUpdate {
  const ToolCallUpdate({
    required this.toolCallId,
    this.isNew = false,
    this.title,
    this.name,
    this.kind,
    this.status,
    this.content,
    this.locations,
    this.rawInput,
    this.rawOutput,
  });

  factory ToolCallUpdate.fromJson(JsonMap json, {required bool isNew}) =>
      ToolCallUpdate(
        toolCallId: json.string('toolCallId') ?? '',
        isNew: isNew,
        title: json.string('title'),
        name: json.string('name'),
        kind: switch (json.string('kind')) {
          final raw? => ToolKind.fromJson(raw),
          null => null,
        },
        status: switch (json.string('status')) {
          final raw? => ToolCallStatus.fromJson(raw),
          null => null,
        },
        content: switch (json.objects('content')) {
          final items? => [for (final i in items) ToolCallContent.fromJson(i)],
          null => null,
        },
        locations: switch (json.objects('locations')) {
          final items? => [for (final i in items) ToolCallLocation.fromJson(i)],
          null => null,
        },
        rawInput: json['rawInput'],
        rawOutput: json['rawOutput'],
      );

  final String toolCallId;
  final bool isNew;
  final String? title;
  final String? name;

  final ToolKind? kind;
  final ToolCallStatus? status;
  final List<ToolCallContent>? content;
  final List<ToolCallLocation>? locations;
  final Object? rawInput;
  final Object? rawOutput;

  @override
  String get sessionUpdate => isNew ? 'tool_call' : 'tool_call_update';

  @override
  JsonMap toJson() => {'sessionUpdate': sessionUpdate, ...toToolCallJson()};

  /// The fields alone, as `session/request_permission` carries them.
  JsonMap toToolCallJson() => withoutNulls({
    'toolCallId': toolCallId,
    'title': title,
    'name': name,
    'kind': kind?.toJson(),
    'status': status?.toJson(),
    'content': switch (content) {
      final items? => [for (final i in items) i.toJson()],
      null => null,
    },
    'locations': switch (locations) {
      final items? => [for (final i in items) i.toJson()],
      null => null,
    },
    'rawInput': rawInput,
    'rawOutput': rawOutput,
  });

  /// [update] laid over this call: present fields replace, absent ones keep.
  ToolCallUpdate merge(ToolCallUpdate update) => ToolCallUpdate(
    toolCallId: toolCallId,
    isNew: isNew,
    title: update.title ?? title,
    name: update.name ?? name,
    kind: update.kind ?? kind,
    status: update.status ?? status,
    content: update.content ?? content,
    locations: update.locations ?? locations,
    rawInput: update.rawInput ?? rawInput,
    rawOutput: update.rawOutput ?? rawOutput,
  );
}

final class PlanUpdate extends SessionUpdate {
  const PlanUpdate(this.entries);

  final List<PlanEntry> entries;

  @override
  String get sessionUpdate => 'plan';

  @override
  JsonMap toJson() => {
    'sessionUpdate': sessionUpdate,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// A slash command the agent accepts in a prompt.
@immutable
final class AvailableCommand {
  const AvailableCommand({
    required this.name,
    required this.description,
    this.inputHint,
  });

  factory AvailableCommand.fromJson(JsonMap json) => AvailableCommand(
    name: json.string('name') ?? '',
    description: json.string('description') ?? '',
    inputHint: json.object('input')?.string('hint'),
  );

  final String name;
  final String description;
  final String? inputHint;

  JsonMap toJson() => withoutNulls({
    'name': name,
    'description': description,
    'input': inputHint == null ? null : {'hint': inputHint},
  });
}

final class AvailableCommandsUpdate extends SessionUpdate {
  const AvailableCommandsUpdate(this.commands);

  final List<AvailableCommand> commands;

  @override
  String get sessionUpdate => 'available_commands_update';

  @override
  JsonMap toJson() => {
    'sessionUpdate': sessionUpdate,
    'availableCommands': [for (final c in commands) c.toJson()],
  };
}

final class CurrentModeUpdate extends SessionUpdate {
  const CurrentModeUpdate(this.currentModeId);

  final String currentModeId;

  @override
  String get sessionUpdate => 'current_mode_update';

  @override
  JsonMap toJson() => {
    'sessionUpdate': sessionUpdate,
    'currentModeId': currentModeId,
  };
}

final class ConfigOptionUpdate extends SessionUpdate {
  const ConfigOptionUpdate(this.configOptions);

  final List<ConfigOption> configOptions;

  @override
  String get sessionUpdate => 'config_option_update';

  @override
  JsonMap toJson() => {
    'sessionUpdate': sessionUpdate,
    'configOptions': [for (final o in configOptions) o.toJson()],
  };
}

final class SessionInfoUpdate extends SessionUpdate {
  const SessionInfoUpdate({this.title, this.updatedAt});

  final String? title;

  /// RFC 3339, as the agent wrote it.
  final String? updatedAt;

  @override
  String get sessionUpdate => 'session_info_update';

  @override
  JsonMap toJson() => withoutNulls({
    'sessionUpdate': sessionUpdate,
    'title': title,
    'updatedAt': updatedAt,
  });
}

@immutable
final class UsageCost {
  const UsageCost({required this.amount, required this.currency});

  factory UsageCost.fromJson(JsonMap json) => UsageCost(
    amount: json.number('amount') ?? 0,
    currency: json.string('currency') ?? '',
  );

  final double amount;
  final String currency;

  JsonMap toJson() => {'amount': amount, 'currency': currency};
}

/// Context used of context available, in tokens.
final class UsageUpdate extends SessionUpdate {
  const UsageUpdate({required this.used, required this.size, this.cost});

  final int used;
  final int size;
  final UsageCost? cost;

  @override
  String get sessionUpdate => 'usage_update';

  @override
  JsonMap toJson() => withoutNulls({
    'sessionUpdate': sessionUpdate,
    'used': used,
    'size': size,
    'cost': cost?.toJson(),
  });
}

/// A `sessionUpdate` kind this package has no class for; [raw] is all of it.
final class UnknownUpdate extends SessionUpdate {
  const UnknownUpdate(this.sessionUpdate, this.raw);

  @override
  final String sessionUpdate;

  String get kind => sessionUpdate;
  final JsonMap raw;

  @override
  JsonMap toJson() => raw;
}
