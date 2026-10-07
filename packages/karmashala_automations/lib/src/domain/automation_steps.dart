import 'dart:convert';

/// When a step after the agent runs, judged by how the run went so far.
enum AutomationStepWhen {
  success,
  failure,
  always;

  static AutomationStepWhen fromName(String? name, AutomationStepWhen or) =>
      values.firstWhere((when) => when.name == name, orElse: () => or);

  bool matches({required bool failed}) => switch (this) {
    AutomationStepWhen.success => !failed,
    AutomationStepWhen.failure => failed,
    AutomationStepWhen.always => true,
  };

  String get label => switch (this) {
    AutomationStepWhen.success => 'If it succeeded',
    AutomationStepWhen.failure => 'If something failed',
    AutomationStepWhen.always => 'Always',
  };
}

/// The steps that may follow the agent, always in this order and at most one
/// of each — a fixed pipeline, not a general engine.
enum AutomationStepKind {
  /// Runs the checkout's project checks on what the agent did.
  check('check'),

  /// Sends the agent's session a message, as a scheduled resume due now.
  tell('tell'),

  /// Files an item in the inbox, which reaches this device and the phone.
  notify('notify');

  const AutomationStepKind(this.storedName);

  final String storedName;

  static AutomationStepKind? fromStored(String? stored) {
    for (final kind in values) {
      if (kind.storedName == stored) return kind;
    }
    return null;
  }

  String get label => switch (this) {
    AutomationStepKind.check => 'Check the result',
    AutomationStepKind.tell => 'Tell the agent',
    AutomationStepKind.notify => 'Notify me',
  };
}

/// One step after the agent. [text] is the message for tell and notify, with
/// `{{…}}` variables ([fillStepText]); a check carries none.
class AutomationStep {
  const AutomationStep({
    required this.kind,
    this.when = AutomationStepWhen.success,
    this.text = '',
  });

  final AutomationStepKind kind;
  final AutomationStepWhen when;
  final String text;

  AutomationStep copyWith({AutomationStepWhen? when, String? text}) =>
      AutomationStep(
        kind: kind,
        when: when ?? this.when,
        text: text ?? this.text,
      );

  Map<String, Object?> toJson() => {
    'kind': kind.storedName,
    'when': when.name,
    if (text.isNotEmpty) 'text': text,
  };

  /// Null for a step this build does not know, which is then left out rather
  /// than read as some other step.
  static AutomationStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = AutomationStepKind.fromStored(json['kind'] as String?);
    if (kind == null) return null;
    return AutomationStep(
      kind: kind,
      when: AutomationStepWhen.fromName(
        json['when'] as String?,
        AutomationStepWhen.success,
      ),
      text: json['text'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationStep &&
      other.kind == kind &&
      other.when == when &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, when, text);

  @override
  String toString() => '${kind.storedName}(${when.name})';
}

/// What an automation does after its agent: the check, tell and notify steps,
/// kept in [AutomationStepKind] order with at most one of each.
class AutomationSteps {
  AutomationSteps(Iterable<AutomationStep> steps, {this.stated = true})
    : after = List.unmodifiable(_ordered(steps));

  const AutomationSteps._(this.after, {this.stated = true});

  /// What every automation did before steps existed: its checks ran after it.
  static const AutomationSteps standard = AutomationSteps._([
    AutomationStep(kind: AutomationStepKind.check),
  ]);

  /// [standard], read from a sender that predates steps — a save from it keeps
  /// what is stored instead of overwriting it.
  static const AutomationSteps unstated = AutomationSteps._([
    AutomationStep(kind: AutomationStepKind.check),
  ], stated: false);

  final List<AutomationStep> after;

  /// False only for [unstated].
  final bool stated;

  bool get checks => of(AutomationStepKind.check) != null;

  AutomationStep? of(AutomationStepKind kind) {
    for (final step in after) {
      if (step.kind == kind) return step;
    }
    return null;
  }

  AutomationSteps put(AutomationStep step) =>
      AutomationSteps([...after.where((s) => s.kind != step.kind), step]);

  AutomationSteps without(AutomationStepKind kind) =>
      AutomationSteps(after.where((s) => s.kind != kind));

  static List<AutomationStep> _ordered(Iterable<AutomationStep> steps) {
    final byKind = <AutomationStepKind, AutomationStep>{
      for (final step in steps) step.kind: step,
    };
    return [for (final kind in AutomationStepKind.values) ?byKind[kind]];
  }

  /// The stored column: null for [standard], so a row an older build wrote
  /// and a row that kept the default read the same.
  String? toColumn() => this == standard
      ? null
      : jsonEncode([for (final step in after) step.toJson()]);

  /// Forgiving: an unreadable column reads as [standard], what the row did
  /// before it had one.
  static AutomationSteps fromColumn(String? raw) {
    if (raw == null || raw.isEmpty) return standard;
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return standard;
    }
  }

  List<Object?> toJson() => [for (final step in after) step.toJson()];

  static AutomationSteps fromJson(Object? json) {
    if (json is! List) return standard;
    return AutomationSteps([
      for (final item in json) ?AutomationStep.fromJson(item),
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (other is! AutomationSteps || other.after.length != after.length) {
      return false;
    }
    for (var i = 0; i < after.length; i++) {
      if (other.after[i] != after[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(after);

  @override
  String toString() => 'steps$after';
}

/// The variables a step's text may name, each with what it stands for.
const Map<String, String> kStepVariables = {
  'automation': 'The automation\'s name',
  'project': 'The checkout it runs in',
  'run.status': '"succeeded" or "failed"',
  'steps.agent.output': 'How the agent\'s run ended',
  'steps.check.output': 'What the checks said',
};

final RegExp _variable = RegExp(r'\{\{\s*([a-zA-Z0-9_.\-]+)\s*\}\}');

/// [text] with each known `{{name}}` replaced by [values]'s entry. An unknown
/// name is left as written, so a typo shows rather than vanishing.
String fillStepText(String text, Map<String, String> values) =>
    text.replaceAllMapped(_variable, (m) => values[m[1]!] ?? m[0]!);

/// How one step after the agent went, recorded on its run.
enum AutomationStepOutcome {
  done,
  failed,
  skipped;

  static AutomationStepOutcome fromName(String? name) => values.firstWhere(
    (outcome) => outcome.name == name,
    orElse: () => AutomationStepOutcome.skipped,
  );
}

/// What one tell or notify step did for one run, in words.
class AutomationStepResult {
  const AutomationStepResult({
    required this.kind,
    required this.outcome,
    required this.detail,
    required this.at,
  });

  final AutomationStepKind kind;
  final AutomationStepOutcome outcome;
  final String detail;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'kind': kind.storedName,
    'outcome': outcome.name,
    'detail': detail,
    'at': at.toUtc().toIso8601String(),
  };

  static AutomationStepResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = AutomationStepKind.fromStored(json['kind'] as String?);
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    if (kind == null || at == null) return null;
    return AutomationStepResult(
      kind: kind,
      outcome: AutomationStepOutcome.fromName(json['outcome'] as String?),
      detail: json['detail'] as String? ?? '',
      at: at.toUtc(),
    );
  }

  static List<AutomationStepResult> listFromJson(Object? json) =>
      json is List ? [for (final item in json) ?fromJson(item)] : const [];

  static List<AutomationStepResult> listFromColumn(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return listFromJson(jsonDecode(raw));
    } on FormatException {
      return const [];
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AutomationStepResult &&
      other.kind == kind &&
      other.outcome == outcome &&
      other.detail == detail &&
      other.at == at;

  @override
  int get hashCode => Object.hash(kind, outcome, detail, at);
}
