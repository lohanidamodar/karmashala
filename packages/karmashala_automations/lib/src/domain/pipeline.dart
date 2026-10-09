import 'dart:convert';

/// Where a stage's agent works.
enum PipelineWorkspace {
  /// The checkout itself, told to change nothing.
  source('source', 'Checkout, read-only'),

  /// A worktree of its own, on a new branch.
  newWorktree('new_worktree', 'New worktree'),

  /// The worktree the nearest earlier stage worked in.
  previousWorktree('previous_worktree', "Previous stage's worktree");

  const PipelineWorkspace(this.storedName, this.label);

  final String storedName;
  final String label;

  bool get writes => this != PipelineWorkspace.source;

  static PipelineWorkspace fromStored(Object? stored) => values.firstWhere(
    (w) => w.storedName == stored,
    orElse: () => PipelineWorkspace.source,
  );
}

/// What has to happen before the run moves on from a stage.
enum PipelineGateKind {
  /// Moves on as soon as the stage's agent finishes its turn.
  auto('auto', 'Go on'),

  /// Waits for a person to read, edit and approve the hand-off.
  approval('approval', 'Ask me'),

  /// Runs checks in the stage's workspace; a failing or stale reading stops
  /// the run or loops back.
  check('check', 'Run checks');

  const PipelineGateKind(this.storedName, this.label);

  final String storedName;
  final String label;

  static PipelineGateKind fromStored(Object? stored) => values.firstWhere(
    (g) => g.storedName == stored,
    orElse: () => PipelineGateKind.approval,
  );
}

/// The default cap on loop-backs from one stage.
const int kPipelineLoopCap = 2;

/// The most loop-backs a stage may ask for.
const int kPipelineLoopCapMax = 5;

/// One stage: an agent session with a role, where it works, its instruction
/// and the gate after it.
class PipelineStage {
  const PipelineStage({
    required this.role,
    required this.instruction,
    this.agentInstallationId,
    this.modelId,
    this.permissionMode,
    this.workspace = PipelineWorkspace.source,
    this.gate = PipelineGateKind.auto,
    this.checkCommand = '',
    this.loopBackTo,
    this.loopCap = kPipelineLoopCap,
  });

  /// Plan, Implement, Review — its title and, as [key], its template name.
  final String role;

  /// A template: `{{input}}`, `{{plan.answer}}`, `{{plan.artifact:spec.md}}`,
  /// `{{implement.worktree}}`, `{{loop.feedback}}` ([kPipelineFieldHelp]).
  final String instruction;

  /// Null starts the checkout's default agent.
  final String? agentInstallationId;
  final String? modelId;

  /// Canonical `PermissionSelection`; null follows Settings.
  final String? permissionMode;
  final PipelineWorkspace workspace;
  final PipelineGateKind gate;

  /// With [PipelineGateKind.check]: one command line; blank runs the
  /// checkout's project checks.
  final String checkCommand;

  /// The [key] of an earlier (or this) stage to go back to when this stage
  /// fails its check or answers `VERDICT: FAIL`.
  final String? loopBackTo;
  final int loopCap;

  String get key => pipelineStageKey(role);

  PipelineStage copyWith({
    String? role,
    String? instruction,
    String? agentInstallationId,
    bool clearAgent = false,
    String? modelId,
    bool clearModel = false,
    String? permissionMode,
    bool clearPermission = false,
    PipelineWorkspace? workspace,
    PipelineGateKind? gate,
    String? checkCommand,
    String? loopBackTo,
    bool clearLoopBack = false,
    int? loopCap,
  }) => PipelineStage(
    role: role ?? this.role,
    instruction: instruction ?? this.instruction,
    agentInstallationId: clearAgent
        ? null
        : agentInstallationId ?? this.agentInstallationId,
    modelId: clearModel ? null : modelId ?? this.modelId,
    permissionMode: clearPermission
        ? null
        : permissionMode ?? this.permissionMode,
    workspace: workspace ?? this.workspace,
    gate: gate ?? this.gate,
    checkCommand: checkCommand ?? this.checkCommand,
    loopBackTo: clearLoopBack ? null : loopBackTo ?? this.loopBackTo,
    loopCap: loopCap ?? this.loopCap,
  );

  Map<String, Object?> toJson() => {
    'role': role,
    'instruction': instruction,
    'agentInstallationId': ?agentInstallationId,
    'modelId': ?modelId,
    'permissionMode': ?permissionMode,
    'workspace': workspace.storedName,
    'gate': gate.storedName,
    if (checkCommand.isNotEmpty) 'checkCommand': checkCommand,
    'loopBackTo': ?loopBackTo,
    if (loopBackTo != null) 'loopCap': loopCap,
  };

  static PipelineStage fromJson(Map<String, Object?> json) => PipelineStage(
    role: json['role'] as String? ?? 'Stage',
    instruction: json['instruction'] as String? ?? '',
    agentInstallationId: json['agentInstallationId'] as String?,
    modelId: json['modelId'] as String?,
    permissionMode: json['permissionMode'] as String?,
    workspace: PipelineWorkspace.fromStored(json['workspace']),
    gate: PipelineGateKind.fromStored(json['gate']),
    checkCommand: json['checkCommand'] as String? ?? '',
    loopBackTo: json['loopBackTo'] as String?,
    loopCap: ((json['loopCap'] as num?)?.toInt() ?? kPipelineLoopCap).clamp(
      0,
      kPipelineLoopCapMax,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is PipelineStage &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// `Implement code` → `implement_code`: how a role is named in a template.
String pipelineStageKey(String role) {
  final key = role
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return key.isEmpty ? 'stage' : key;
}

/// An ordered list of stages, saved by a person or built in.
class PipelineDefinition {
  const PipelineDefinition({
    required this.id,
    required this.name,
    required this.stages,
    this.description = '',
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;
  final List<PipelineStage> stages;

  /// One of [kPipelineTemplates]: copied to be changed, never saved over.
  final bool builtIn;

  int indexOfKey(String key) => stages.indexWhere((s) => s.key == key);

  PipelineDefinition copyWith({
    String? id,
    String? name,
    String? description,
    List<PipelineStage>? stages,
    bool? builtIn,
  }) => PipelineDefinition(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    stages: stages ?? this.stages,
    builtIn: builtIn ?? this.builtIn,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'stages': [for (final stage in stages) stage.toJson()],
    if (builtIn) 'builtIn': true,
  };

  static PipelineDefinition fromJson(Map<String, Object?> json) =>
      PipelineDefinition(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Pipeline',
        description: json['description'] as String? ?? '',
        stages: [
          for (final stage in (json['stages'] as List<Object?>?) ?? const [])
            if (stage is Map)
              PipelineStage.fromJson(stage.cast<String, Object?>()),
        ],
        builtIn: json['builtIn'] == true,
      );

  @override
  bool operator ==(Object other) =>
      other is PipelineDefinition &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The most stages one pipeline may have.
const int kPipelineMaxStages = 8;

/// Why [definition] cannot run, or null when it can.
String? pipelineDefinitionRefusal(PipelineDefinition definition) {
  if (definition.name.trim().isEmpty) return 'A pipeline needs a name.';
  final stages = definition.stages;
  if (stages.isEmpty) return 'A pipeline needs at least one stage.';
  if (stages.length > kPipelineMaxStages) {
    return 'A pipeline has at most $kPipelineMaxStages stages.';
  }
  final keys = <String>{};
  for (var i = 0; i < stages.length; i++) {
    final stage = stages[i];
    if (stage.role.trim().isEmpty) return 'Stage ${i + 1} needs a role name.';
    if (!keys.add(stage.key)) {
      return 'Two stages are both called "${stage.role}"; each role needs its '
          'own name.';
    }
    if (stage.instruction.trim().isEmpty) {
      return '${stage.role} needs an instruction.';
    }
    if (i == 0 && stage.workspace == PipelineWorkspace.previousWorktree) {
      return "${stage.role} is first, so there is no previous stage's "
          'worktree to work in.';
    }
    if (stage.workspace == PipelineWorkspace.previousWorktree &&
        !stages.take(i).any((s) => s.workspace.writes)) {
      return '${stage.role} works in the previous worktree, but no stage '
          'before it has one.';
    }
    final loop = stage.loopBackTo;
    if (loop != null) {
      final target = definition.indexOfKey(loop);
      if (target < 0 || target > i) {
        return '${stage.role} loops back to "$loop", which is not this stage '
            'or one before it.';
      }
    }
    for (final field in pipelineFieldsIn(stage.instruction)) {
      final refusal = _fieldRefusal(field, stages, i);
      if (refusal != null) return '${stage.role}: $refusal';
    }
  }
  return null;
}

String? _fieldRefusal(PipelineField field, List<PipelineStage> stages, int at) {
  switch (field.scope) {
    case 'input':
    case 'loop':
    case 'previous':
      return null;
  }
  final index = stages.indexWhere((s) => s.key == field.scope);
  if (index < 0) return '{{${field.raw}}} names no stage.';
  if (index < at) return null;
  // A later stage's output reaches this one only through a loop back to it.
  final reachedAgain = stages.skip(index).any((s) {
    final target = s.loopBackTo;
    if (target == null) return false;
    final to = stages.indexWhere((t) => t.key == target);
    return to >= 0 && to <= at;
  });
  return reachedAgain
      ? null
      : '{{${field.raw}}} names a stage that has not run yet.';
}

/// One `{{scope.name}}` or `{{scope.artifact:arg}}` in an instruction.
class PipelineField {
  const PipelineField(this.raw, this.scope, this.name, [this.arg]);

  final String raw;
  final String scope;
  final String name;
  final String? arg;
}

final _fieldPattern = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}');

/// Every field [template] names, in order.
List<PipelineField> pipelineFieldsIn(String template) => [
  for (final match in _fieldPattern.allMatches(template))
    ?_parseField(match.group(1)!),
];

PipelineField? _parseField(String raw) {
  if (raw == 'input') return PipelineField(raw, 'input', 'text');
  final dot = raw.indexOf('.');
  if (dot <= 0) return null;
  final scope = raw.substring(0, dot);
  final rest = raw.substring(dot + 1);
  final colon = rest.indexOf(':');
  if (colon < 0) return PipelineField(raw, scope, rest);
  return PipelineField(
    raw,
    scope,
    rest.substring(0, colon),
    rest.substring(colon + 1).trim(),
  );
}

/// What a person can put in an instruction, for the editor's insert menu.
const List<(String, String)> kPipelineFieldHelp = [
  ('{{input}}', 'What the run was started with'),
  ('{{previous.answer}}', "The previous stage's hand-off"),
  ('{{<stage>.answer}}', "A stage's final answer, as approved"),
  ('{{<stage>.artifact:spec.md}}', 'An artifact a stage wrote, by name'),
  ('{{<stage>.artifacts}}', "A stage's artifacts, listed"),
  ('{{<stage>.worktree}}', "Where a stage's worktree is"),
  ('{{<stage>.branch}}', "A stage's branch"),
  ('{{<stage>.checks}}', "A stage's check result"),
  ('{{loop.feedback}}', 'Why the run looped back here'),
  ('{{loop.count}}', 'How many times it has looped back'),
];

/// Fills [template]'s fields from [valueOf]; a field it answers null for is
/// left as written, so a typo shows rather than vanishing.
String fillPipelineTemplate(
  String template,
  String? Function(PipelineField field) valueOf,
) => template.replaceAllMapped(_fieldPattern, (match) {
  final field = _parseField(match.group(1)!);
  if (field == null) return match.group(0)!;
  return valueOf(field) ?? match.group(0)!;
});

/// A review stage's last word: `VERDICT: PASS` or `VERDICT: FAIL`.
enum PipelineVerdict { pass, fail, none }

/// The last `VERDICT:` line of [answer].
PipelineVerdict pipelineVerdictOf(String? answer) {
  if (answer == null) return PipelineVerdict.none;
  final matches = RegExp(
    r'VERDICT\s*:\s*\**\s*(PASS|FAIL)',
    caseSensitive: false,
  ).allMatches(answer).toList();
  if (matches.isEmpty) return PipelineVerdict.none;
  return matches.last.group(1)!.toUpperCase() == 'PASS'
      ? PipelineVerdict.pass
      : PipelineVerdict.fail;
}

const _verdictAsk =
    'End your answer with one line, `VERDICT: PASS` or `VERDICT: FAIL`.';

/// The built-in templates, Plan → Implement → Review first.
final List<PipelineDefinition> kPipelineTemplates = [
  const PipelineDefinition(
    id: 'builtin:plan-implement-review',
    name: 'Plan → Implement → Review',
    description:
        'Plan read-only into spec.md, implement it in a worktree after you '
        'approve, then review the change; a failed review goes back once or '
        'twice.',
    builtIn: true,
    stages: [
      PipelineStage(
        role: 'Plan',
        instruction:
            'Plan this task. Explore the code read-only and change nothing.\n\n'
            'Task: {{input}}\n\n'
            'Write the plan as a file named spec.md outside the checkout and '
            'show it with the artifact_show tool, then answer with a short '
            'summary of the plan.',
        gate: PipelineGateKind.approval,
      ),
      PipelineStage(
        role: 'Implement',
        instruction:
            'Implement this plan.\n\nTask: {{input}}\n\n'
            '{{plan.artifact:spec.md}}\n\n'
            '{{loop.feedback}}\n\n'
            'Commit your work on this branch, then answer with what you '
            'changed.',
        workspace: PipelineWorkspace.newWorktree,
      ),
      PipelineStage(
        role: 'Review',
        instruction:
            'Review the change in this worktree (branch {{implement.branch}}) '
            'against the plan. Do not edit files.\n\n'
            'Task: {{input}}\n\n{{plan.artifact:spec.md}}\n\n'
            'What the implementer said:\n{{implement.answer}}\n\n$_verdictAsk',
        workspace: PipelineWorkspace.previousWorktree,
        loopBackTo: 'implement',
      ),
    ],
  ),
  const PipelineDefinition(
    id: 'builtin:implement-test-fix',
    name: 'Implement → Test → Fix loop',
    description:
        'Implement in a worktree, run the checks there, and send failures '
        'back to the implementer until they pass or the loop cap is reached.',
    builtIn: true,
    stages: [
      PipelineStage(
        role: 'Implement',
        instruction:
            'Implement this.\n\nTask: {{input}}\n\n{{loop.feedback}}\n\n'
            'Commit your work on this branch, then answer with what you '
            'changed.',
        workspace: PipelineWorkspace.newWorktree,
      ),
      PipelineStage(
        role: 'Test',
        instruction:
            'Test the change in this worktree. Add or run focused tests for '
            'it; fix nothing yourself.\n\nTask: {{input}}\n\n'
            'What the implementer said:\n{{implement.answer}}\n\n$_verdictAsk',
        workspace: PipelineWorkspace.previousWorktree,
        gate: PipelineGateKind.check,
        loopBackTo: 'implement',
      ),
    ],
  ),
  const PipelineDefinition(
    id: 'builtin:research-write',
    name: 'Research → Write',
    description:
        'Research read-only into notes.md, then write the result from those '
        'notes.',
    builtIn: true,
    stages: [
      PipelineStage(
        role: 'Research',
        instruction:
            'Research this, read-only; change no files.\n\n'
            'Question: {{input}}\n\n'
            'Write your findings to a file named notes.md outside the '
            'checkout and show it with the artifact_show tool, then answer '
            'with a short summary.',
      ),
      PipelineStage(
        role: 'Write',
        instruction:
            'Write the answer to this from the research below.\n\n'
            'Question: {{input}}\n\n{{research.artifact:notes.md}}\n\n'
            'Show what you write with the artifact_show tool, then answer '
            'with it.',
      ),
    ],
  ),
];

/// The template or saved pipeline called [idOrName], case-insensitively.
PipelineDefinition? pipelineTemplateNamed(String idOrName) {
  final wanted = idOrName.trim().toLowerCase();
  for (final template in kPipelineTemplates) {
    if (template.id == idOrName || template.name.toLowerCase() == wanted) {
      return template;
    }
  }
  return null;
}
