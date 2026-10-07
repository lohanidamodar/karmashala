part of '../data_change.dart';

// What a session's agent offers at runtime and is not on its row: the modes
// an ACP agent lets a client switch between, and the settings (a model, a
// flag) it exposes as config options. Told to every client
// as the agent announces or changes them; nothing of it is stored.

DataChange? _sessionsChangeFromJson(String name, Map<String, Object?> json) =>
    switch (name) {
      'sessionModesChanged' => SessionModesChanged(
        sessionId: json['sessionId']! as String,
        currentModeId: json['currentModeId'] as String?,
        availableModes: [
          for (final mode in (json['availableModes'] as List?) ?? const [])
            SessionModeOption.fromJson((mode as Map).cast<String, Object?>()),
        ],
      ),
      'sessionConfigOptionsChanged' => SessionConfigOptionsChanged(
        sessionId: json['sessionId']! as String,
        options: [
          for (final option in (json['options'] as List?) ?? const [])
            SessionConfigOption.fromJson(
              (option as Map).cast<String, Object?>(),
            ),
        ],
      ),
      'sessionUsageChanged' => SessionUsageChanged.fromJson(json),
      'sessionActiveModelChanged' => SessionActiveModelChanged.fromJson(json),
      'sessionQueueChanged' => SessionQueueChanged.fromJson(json),
      'sessionAgentChanged' => SessionAgentChanged.fromJson(json),
      'sessionCommandsChanged' => SessionCommandsChanged.fromJson(json),
      'sessionPromptKindsChanged' => SessionPromptKindsChanged(
        sessionId: json['sessionId']! as String,
        images: json['images'] == true,
      ),
      'sessionNoticed' => SessionNoticed(
        sessionId: json['sessionId']! as String,
        message: json['message'] as String? ?? '',
      ),
      _ => null,
    };

/// One mode an agent offers, in its own words.
final class SessionModeOption {
  const SessionModeOption({
    required this.id,
    required this.name,
    this.description,
  });

  factory SessionModeOption.fromJson(Map<String, Object?> json) =>
      SessionModeOption(
        id: json['id']! as String,
        name: json['name'] as String? ?? json['id']! as String,
        description: json['description'] as String?,
      );

  final String id;
  final String name;
  final String? description;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': ?description,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionModeOption &&
      other.id == id &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, description);
}

/// Session [sessionId]'s agent now offers [availableModes] and is in
/// [currentModeId] — null when it has not said which. An empty list is an
/// agent with no modes to set.
final class SessionModesChanged extends DataChange {
  const SessionModesChanged({
    required this.sessionId,
    required this.currentModeId,
    required this.availableModes,
  });

  final String sessionId;
  final String? currentModeId;
  final List<SessionModeOption> availableModes;

  /// The mode the agent is in, as offered, or null when it named one that is
  /// not in the list.
  SessionModeOption? get current {
    for (final mode in availableModes) {
      if (mode.id == currentModeId) return mode;
    }
    return null;
  }

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionModesChanged',
    'sessionId': sessionId,
    'currentModeId': ?currentModeId,
    'availableModes': [for (final mode in availableModes) mode.toJson()],
  };
}

/// One value a `select` config option can take, in the agent's words.
final class SessionConfigChoice {
  const SessionConfigChoice({
    required this.value,
    required this.name,
    this.description,
    this.group,
  });

  factory SessionConfigChoice.fromJson(Map<String, Object?> json) =>
      SessionConfigChoice(
        value: json['value']! as String,
        name: json['name'] as String? ?? json['value']! as String,
        description: json['description'] as String?,
        group: json['group'] as String?,
      );

  final String value;
  final String name;
  final String? description;

  /// The heading the agent grouped this choice under, when it grouped them.
  final String? group;

  Map<String, Object?> toJson() => {
    'value': value,
    'name': name,
    'description': ?description,
    'group': ?group,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionConfigChoice &&
      other.value == value &&
      other.name == name &&
      other.description == description &&
      other.group == group;

  @override
  int get hashCode => Object.hash(value, name, description, group);
}

/// A setting an agent exposes on a session (ACP `configOptions`): a `select`
/// among [choices] whose [currentValue] is a choice's value, or a `boolean`
/// whose [currentValue] is a bool. Any other [type] is carried as the agent
/// sent it and offered no control.
final class SessionConfigOption {
  const SessionConfigOption({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.category,
    this.currentValue,
    this.choices = const [],
  });

  factory SessionConfigOption.fromJson(Map<String, Object?> json) =>
      SessionConfigOption(
        id: json['id']! as String,
        name: json['name'] as String? ?? json['id']! as String,
        type: json['type'] as String? ?? '',
        description: json['description'] as String?,
        category: json['category'] as String?,
        currentValue: switch (json['currentValue']) {
          final String value => value,
          final bool value => value,
          _ => null,
        },
        choices: [
          for (final choice in (json['choices'] as List?) ?? const [])
            SessionConfigChoice.fromJson(
              (choice as Map).cast<String, Object?>(),
            ),
        ],
      );

  final String id;
  final String name;

  /// `select`, `boolean`, or whatever else the agent said.
  final String type;
  final String? description;

  /// The agent's own heading for this setting, when it gave one.
  final String? category;

  /// A `String` for a `select`, a `bool` for a `boolean`; null when the agent
  /// sent neither.
  final Object? currentValue;
  final List<SessionConfigChoice> choices;

  bool get isSelect => type == 'select';
  bool get isBoolean => type == 'boolean';

  /// The agent's `model` option, which stands where a session's model is
  /// shown.
  bool get isModel => id == 'model' || category == 'model';

  /// An option that is the session's mode again: an agent may expose its
  /// modes both as `modes` and as a `mode` config option, and the mode
  /// picker already stands for it.
  bool get isMode => category == 'mode' || id == 'mode';

  /// The choice [currentValue] names, or null when it names none offered.
  SessionConfigChoice? get current {
    for (final choice in choices) {
      if (choice.value == currentValue) return choice;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'description': ?description,
    'category': ?category,
    'currentValue': ?currentValue,
    'choices': [for (final choice in choices) choice.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is SessionConfigOption &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      other.description == description &&
      other.category == category &&
      other.currentValue == currentValue &&
      _sameChoices(other.choices);

  bool _sameChoices(List<SessionConfigChoice> other) {
    if (other.length != choices.length) return false;
    for (var i = 0; i < choices.length; i++) {
      if (other[i] != choices[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    type,
    description,
    category,
    currentValue,
    Object.hashAll(choices),
  );
}

/// Session [sessionId]'s agent now exposes [options], each with the value it
/// holds. The whole list every time, as the agent tells it; an empty list is
/// an agent with nothing to set.
final class SessionConfigOptionsChanged extends DataChange {
  const SessionConfigOptionsChanged({
    required this.sessionId,
    required this.options,
  });

  final String sessionId;
  final List<SessionConfigOption> options;

  /// The option under [id], or null.
  SessionConfigOption? option(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionConfigOptionsChanged',
    'sessionId': sessionId,
    'options': [for (final option in options) option.toJson()],
  };
}

/// Session [sessionId]'s agent reported its usage (`usage_update`): the
/// tokens in its context of the window's size, and its cumulative cost when
/// it gives one. Told as it arrives, mid-turn too; the server also keeps it,
/// so `sessions.stats` answers the same after a restart.
final class SessionUsageChanged extends DataChange {
  const SessionUsageChanged({
    required this.sessionId,
    required this.contextUsed,
    required this.contextSize,
    this.costAmount,
    this.costCurrency,
  });

  factory SessionUsageChanged.fromJson(Map<String, Object?> json) {
    final cost = json['costAmount'];
    return SessionUsageChanged(
      sessionId: json['sessionId']! as String,
      contextUsed: json['contextUsed'] as int? ?? 0,
      contextSize: json['contextSize'] as int? ?? 0,
      costAmount: cost is num ? cost.toDouble() : null,
      costCurrency: json['costCurrency'] as String?,
    );
  }

  final String sessionId;
  final int contextUsed;
  final int contextSize;
  final double? costAmount;

  /// ISO 4217, as the agent wrote it.
  final String? costCurrency;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionUsageChanged',
    'sessionId': sessionId,
    'contextUsed': contextUsed,
    'contextSize': contextSize,
    'costAmount': ?costAmount,
    'costCurrency': ?costCurrency,
  };
}

/// Where a session's active model was read from.
enum ActiveModelSource {
  /// The agent's own protocol: an ACP agent's `model` option, or what a
  /// Karmashala bridge says the CLI under it resolved.
  agent,

  /// The session's record: the model its transcript names on its newest turn.
  record,
}

/// The model session [sessionId]'s agent last said it is running — read from
/// the agent, never from a setting — and when that was observed. A session
/// nothing has reported for yet has no change at all.
final class SessionActiveModelChanged extends DataChange {
  const SessionActiveModelChanged({
    required this.sessionId,
    required this.modelId,
    required this.observedAt,
    this.source = ActiveModelSource.record,
  });

  factory SessionActiveModelChanged.fromJson(Map<String, Object?> json) =>
      SessionActiveModelChanged(
        sessionId: json['sessionId']! as String,
        modelId: json['modelId']! as String,
        observedAt:
            DateTime.tryParse(json['observedAt'] as String? ?? '')?.toUtc() ??
            DateTime.utc(1970),
        source:
            ActiveModelSource.values
                .where((source) => source.name == json['source'])
                .firstOrNull ??
            ActiveModelSource.record,
      );

  final String sessionId;

  /// The agent's own id for the model, as it wrote it.
  final String modelId;
  final DateTime observedAt;
  final ActiveModelSource source;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionActiveModelChanged',
    'sessionId': sessionId,
    'modelId': modelId,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'source': source.name,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionActiveModelChanged &&
      other.sessionId == sessionId &&
      other.modelId == modelId &&
      other.observedAt == observedAt &&
      other.source == source;

  @override
  int get hashCode => Object.hash(sessionId, modelId, observedAt, source);
}

/// Session [sessionId]'s queued messages now stand at [messages] — queued,
/// delivering and failed, in the order they go. A delivered or cancelled one
/// has left the list; a client replaces its copy whole.
final class SessionQueueChanged extends DataChange {
  const SessionQueueChanged({required this.sessionId, required this.messages});

  factory SessionQueueChanged.fromJson(Map<String, Object?> json) =>
      SessionQueueChanged(
        sessionId: json['sessionId']! as String,
        messages: [
          for (final row in (json['messages'] as List?) ?? const [])
            QueuedMessage.fromJson((row as Map).cast<String, Object?>()),
        ],
      );

  final String sessionId;
  final List<QueuedMessage> messages;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionQueueChanged',
    'sessionId': sessionId,
    'messages': [for (final message in messages) message.toJson()],
  };
}

/// Session [sessionId]'s agent was switched in place (`sessions.switchAgent`):
/// its row now names [agentInstallationId], and [spans] are every agent it
/// ran under, in order. A client re-reads what follows the row's agent — its
/// kind, its transcript, its panes.
final class SessionAgentChanged extends DataChange {
  const SessionAgentChanged({
    required this.sessionId,
    required this.agentInstallationId,
    required this.spans,
  });

  factory SessionAgentChanged.fromJson(Map<String, Object?> json) =>
      SessionAgentChanged(
        sessionId: json['sessionId']! as String,
        agentInstallationId: json['agentInstallationId']! as String,
        spans: [
          for (final row in (json['spans'] as List?) ?? const [])
            SessionAgentSpan.fromJson((row as Map).cast<String, Object?>()),
        ],
      );

  final String sessionId;
  final String agentInstallationId;
  final List<SessionAgentSpan> spans;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionAgentChanged',
    'sessionId': sessionId,
    'agentInstallationId': agentInstallationId,
    'spans': [for (final span in spans) span.toJson()],
  };
}

/// A slash command a session's agent accepts in a prompt (ACP
/// `available_commands_update`), in its own words. [name] has no slash.
final class SessionCommand {
  const SessionCommand({
    required this.name,
    required this.description,
    this.hint,
  });

  factory SessionCommand.fromJson(Map<String, Object?> json) => SessionCommand(
    name: json['name']! as String,
    description: json['description'] as String? ?? '',
    hint: json['hint'] as String?,
  );

  final String name;
  final String description;

  /// What the agent says to type after the command, when it takes input.
  final String? hint;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'hint': ?hint,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionCommand &&
      other.name == name &&
      other.description == description &&
      other.hint == hint;

  @override
  int get hashCode => Object.hash(name, description, hint);
}

/// Session [sessionId]'s agent now accepts [commands]: the whole list each
/// time, as the agent tells it. Not stored; an empty list is none.
final class SessionCommandsChanged extends DataChange {
  const SessionCommandsChanged({
    required this.sessionId,
    required this.commands,
  });

  factory SessionCommandsChanged.fromJson(Map<String, Object?> json) =>
      SessionCommandsChanged(
        sessionId: json['sessionId']! as String,
        commands: [
          for (final row in (json['commands'] as List?) ?? const [])
            SessionCommand.fromJson((row as Map).cast<String, Object?>()),
        ],
      );

  final String sessionId;
  final List<SessionCommand> commands;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionCommandsChanged',
    'sessionId': sessionId,
    'commands': [for (final command in commands) command.toJson()],
  };
}

/// Something the server has to say of session [sessionId] to whoever watches
/// it — what a message it delivered could not carry — in a sentence. Told
/// once, never stored.
final class SessionNoticed extends DataChange {
  const SessionNoticed({required this.sessionId, required this.message});

  final String sessionId;
  final String message;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionNoticed',
    'sessionId': sessionId,
    'message': message,
  };
}

/// What session [sessionId]'s agent takes in a prompt beyond text, as it
/// declared at its start (ACP `promptCapabilities`): [images] when an
/// attached image reaches it as an image rather than as its path. Not stored.
final class SessionPromptKindsChanged extends DataChange {
  const SessionPromptKindsChanged({
    required this.sessionId,
    required this.images,
  });

  final String sessionId;
  final bool images;

  @override
  Map<String, Object?> toJson() => {
    'change': 'sessionPromptKindsChanged',
    'sessionId': sessionId,
    'images': images,
  };
}
