part of '../data_change.dart';

// What a session's agent offers at runtime and is not on its row: the modes
// an ACP agent lets a client switch between, and the settings (a model, a
// flag) it exposes as config options (ACP design, C5). Told to every client
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
  bool get isModel => id == 'model';

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
