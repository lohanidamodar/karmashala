import 'dart:convert';

/// How long one check may run when nothing says otherwise: long enough for a
/// slow suite, short enough that a watch mode or a prompt does not hold a run
/// for good.
const Duration kCheckTimeLimit = Duration(minutes: 30);

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
  /// Runs its own commands on what the agent did; a non-zero exit fails the
  /// run.
  check('check'),

  /// Runs a shell command in the run's checkout or worktree. Variables reach
  /// it only as environment variables ([stepEnvironment]).
  command('command'),

  /// POSTs JSON to a URL, its body a template of JSON-escaped values.
  webhook('webhook'),

  /// Starts a pipeline run, attributed to the automation, as background work.
  /// The run ends waiting on it; the pipeline carries on by itself.
  pipeline('pipeline'),

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
    AutomationStepKind.command => 'Run a command',
    AutomationStepKind.webhook => 'Call a webhook',
    AutomationStepKind.pipeline => 'Run a pipeline',
    AutomationStepKind.tell => 'Tell the agent',
    AutomationStepKind.notify => 'Notify me',
  };

  /// How long the step may take when its owner names nothing.
  Duration get defaultTimeout => switch (this) {
    AutomationStepKind.check => kCheckTimeLimit,
    AutomationStepKind.command => const Duration(minutes: 10),
    _ => const Duration(seconds: 30),
  };
}

/// One step after the agent. [text] is the message for tell and notify, with
/// `{{…}}` variables ([fillStepText]); the command for a command step, never
/// filled; the body template for a webhook ([fillJsonBody]); a check's
/// commands, one a line ([checkCommands]); a pipeline's input, filled.
class AutomationStep {
  const AutomationStep({
    required this.kind,
    this.when = AutomationStepWhen.success,
    this.text = '',
    this.name = '',
    this.url = '',
    this.allowPrivate = false,
    this.timeoutSeconds,
    this.pipelineId = '',
    this.repositoryId,
  });

  final AutomationStepKind kind;
  final AutomationStepWhen when;
  final String text;

  /// What a check is called in its run's rows; empty names it by its command.
  final String name;

  /// Where a webhook step posts.
  final String url;

  /// A webhook step may post to private, loopback and link-local addresses.
  final bool allowPrivate;

  /// Null is [AutomationStepKind.defaultTimeout].
  final int? timeoutSeconds;

  /// The template or saved pipeline a pipeline step starts.
  final String pipelineId;

  /// The checkout a pipeline step runs in; null is the automation's own.
  final String? repositoryId;

  Duration get timeout => timeoutSeconds == null || timeoutSeconds! <= 0
      ? kind.defaultTimeout
      : Duration(seconds: timeoutSeconds!);

  /// A check's commands, one a line, blank lines dropped.
  List<String> get checkCommands => [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  AutomationStep copyWith({
    AutomationStepWhen? when,
    String? text,
    String? name,
    String? url,
    bool? allowPrivate,
    int? timeoutSeconds,
    String? pipelineId,
    String? repositoryId,
    bool clearRepository = false,
  }) => AutomationStep(
    kind: kind,
    when: when ?? this.when,
    text: text ?? this.text,
    name: name ?? this.name,
    url: url ?? this.url,
    allowPrivate: allowPrivate ?? this.allowPrivate,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    pipelineId: pipelineId ?? this.pipelineId,
    repositoryId: clearRepository ? null : repositoryId ?? this.repositoryId,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.storedName,
    'when': when.name,
    if (text.isNotEmpty) 'text': text,
    if (name.isNotEmpty) 'name': name,
    if (url.isNotEmpty) 'url': url,
    if (allowPrivate) 'allowPrivate': true,
    'timeoutSeconds': ?timeoutSeconds,
    if (pipelineId.isNotEmpty) 'pipelineId': pipelineId,
    'repositoryId': ?repositoryId,
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
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
      allowPrivate: json['allowPrivate'] == true,
      timeoutSeconds: json['timeoutSeconds'] as int?,
      pipelineId: json['pipelineId'] as String? ?? '',
      repositoryId: json['repositoryId'] as String?,
    );
  }

  /// Why this step cannot be saved, or null when it can.
  String? get refusal => switch (kind) {
    AutomationStepKind.check when text.trim().isEmpty =>
      'Say what command checks the result, like "flutter test".',
    AutomationStepKind.command when text.trim().isEmpty =>
      'Say what command to run.',
    AutomationStepKind.command when text.contains('{{') =>
      'A command never has variables put into it. Read them from the '
          'environment instead, as "\$KARMASHALA_GITHUB_PR_BRANCH" (or '
          '\$env:KARMASHALA_GITHUB_PR_BRANCH on Windows).',
    AutomationStepKind.webhook => webhookStepRefusal(url, text),
    AutomationStepKind.pipeline when pipelineId.trim().isEmpty =>
      'Pick the pipeline to run.',
    AutomationStepKind.pipeline when text.trim().isEmpty =>
      'Say what the pipeline is to do: every stage gets it as {{input}}.',
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is AutomationStep &&
      other.kind == kind &&
      other.when == when &&
      other.text == text &&
      other.name == name &&
      other.url == url &&
      other.allowPrivate == allowPrivate &&
      other.timeoutSeconds == timeoutSeconds &&
      other.pipelineId == pipelineId &&
      other.repositoryId == repositoryId;

  @override
  int get hashCode => Object.hash(
    kind,
    when,
    text,
    name,
    url,
    allowPrivate,
    timeoutSeconds,
    pipelineId,
    repositoryId,
  );

  @override
  String toString() => '${kind.storedName}(${when.name})';
}

/// What an automation does after its agent: the check, tell and notify steps,
/// kept in [AutomationStepKind] order with at most one of each.
class AutomationSteps {
  AutomationSteps(Iterable<AutomationStep> steps, {this.stated = true})
    : after = List.unmodifiable(_ordered(steps));

  const AutomationSteps._(this.after, {this.stated = true});

  /// What every automation did before steps existed: its checkout's project
  /// checks ran after it. A check step with no command still means that, until
  /// [carryProjectChecks] gives it theirs.
  static const AutomationSteps standard = AutomationSteps._([
    AutomationStep(kind: AutomationStepKind.check),
  ]);

  /// Nothing after the agent: where a new automation starts, a check being
  /// optional.
  static const AutomationSteps none = AutomationSteps._([]);

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

  /// The first step that cannot be saved, said as why, or null.
  String? get refusal {
    for (final step in after) {
      if (step.refusal case final why?) return '${step.kind.label}: $why';
    }
    return null;
  }
}

/// The variables a step's text may name, each with what it stands for.
const Map<String, String> kStepVariables = {
  'automation': 'The automation\'s name',
  'project': 'The checkout it runs in',
  'run.status': '"succeeded" or "failed"',
  'steps.agent.output': 'How the agent\'s run ended',
  'steps.check.output': 'What the check said',
  'steps.command.output': 'What the command printed',
  'steps.command.exit_code': 'The command\'s exit code',
  'steps.webhook.status': 'The webhook\'s HTTP status',
  'steps.webhook.output': 'What the webhook answered',
  'steps.pipeline.run': 'The pipeline run it started',
};

/// The environment variable [name] reaches a command as:
/// `github.pr.branch` is `KARMASHALA_GITHUB_PR_BRANCH`.
String stepEnvironmentName(String name) =>
    'KARMASHALA_${name.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '_')}';

/// [values] as a command's environment. The command text is never filled, so
/// no value can become shell syntax; the shell reads them as variables.
Map<String, String> stepEnvironment(Map<String, String> values) => {
  for (final MapEntry(:key, :value) in values.entries)
    stepEnvironmentName(key): value.replaceAll('\u0000', ''),
};

/// [template] with each known `{{name}}` replaced by its value JSON-escaped,
/// for use inside a JSON string. Throws [FormatException] when the result is
/// not JSON.
String fillJsonBody(String template, Map<String, String> values) {
  final filled = template.replaceAllMapped(_variable, (m) {
    final value = values[m[1]!];
    if (value == null) return m[0]!;
    final quoted = jsonEncode(value);
    return quoted.substring(1, quoted.length - 1);
  });
  jsonDecode(filled.trim().isEmpty ? '{}' : filled);
  return filled.trim().isEmpty ? '{}' : filled;
}

/// Why a webhook step to [url] with [body] cannot be saved, or null.
String? webhookStepRefusal(String url, String body) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http') ||
      uri.host.isEmpty) {
    return 'Give it an http or https URL.';
  }
  try {
    fillJsonBody(body, {
      for (final name in _variable.allMatches(body).map((m) => m[1]!))
        name: 'example',
    });
  } on FormatException {
    return 'The body is not JSON. Put variables inside strings, like '
        '{"title": "{{github.pr.title}}"}.';
  }
  return null;
}

final RegExp _variable = RegExp(r'\{\{\s*([a-zA-Z0-9_.\-]+)\s*\}\}');

/// [text] with each known `{{name}}` replaced by [values]'s entry. An unknown
/// name is left as written, so a typo shows rather than vanishing.
String fillStepText(String text, Map<String, String> values) =>
    text.replaceAllMapped(_variable, (m) => values[m[1]!] ?? m[0]!);

/// How one step after the agent went, recorded on its run.
enum AutomationStepOutcome {
  done,
  failed,
  skipped,

  /// A pipeline step's run is under way or held at a gate.
  waiting;

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
    this.pipelineRunId,
  });

  final AutomationStepKind kind;
  final AutomationStepOutcome outcome;
  final String detail;
  final DateTime at;

  /// The pipeline run a pipeline step started.
  final String? pipelineRunId;

  AutomationStepResult copyWith({
    AutomationStepOutcome? outcome,
    String? detail,
    DateTime? at,
  }) => AutomationStepResult(
    kind: kind,
    outcome: outcome ?? this.outcome,
    detail: detail ?? this.detail,
    at: at ?? this.at,
    pipelineRunId: pipelineRunId,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.storedName,
    'outcome': outcome.name,
    'detail': detail,
    'at': at.toUtc().toIso8601String(),
    'pipelineRunId': ?pipelineRunId,
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
      pipelineRunId: json['pipelineRunId'] as String?,
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
      other.at == at &&
      other.pipelineRunId == pipelineRunId;

  @override
  int get hashCode => Object.hash(kind, outcome, detail, at, pipelineRunId);
}
