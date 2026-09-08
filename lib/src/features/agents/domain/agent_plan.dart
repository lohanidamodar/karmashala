import 'dart:convert';

/// What one item on an agent's own plan is in.
///
/// Four states because three of them are words the CLIs actually write and the
/// fourth is the honest answer for one they have not written before.
/// [unrecorded] is named the way [AgentWaitKind.unrecorded] is: a word we do
/// not know is not a state we may guess at, and §19 will not have an unknown
/// reported as a zero — so it counts as neither done nor outstanding.
enum AgentPlanItemState { pending, inProgress, completed, unrecorded }

/// One line of an agent's own plan.
class AgentPlanItem {
  const AgentPlanItem({required this.text, required this.state});

  /// What the agent wrote, verbatim and trimmed.
  ///
  /// Not shortened here: one real Claude Code item in the owner's store is a
  /// 300-character paragraph, and where to cut it is the renderer's decision
  /// rather than the reader's.
  final String text;

  final AgentPlanItemState state;

  @override
  bool operator ==(Object other) =>
      other is AgentPlanItem && other.text == text && other.state == state;

  @override
  int get hashCode => Object.hash(text, state);

  @override
  String toString() => 'AgentPlanItem(${state.name}: $text)';
}

/// **One snapshot of the plan an agent keeps for itself.**
///
/// A value type with real equality, for [SessionActivity]'s reason: the
/// transcript is re-parsed whenever the file moves, and a re-parse that found
/// the same plan must leave the panel asleep rather than hand it a new list of
/// identical items.
class AgentPlan {
  const AgentPlan({required this.items, this.note = ''});

  final List<AgentPlanItem> items;

  /// The agent's own sentence about the plan as a whole, when it wrote one.
  ///
  /// Codex's `update_plan` carries an `explanation`; Claude Code's `TodoWrite`
  /// carries nothing of the kind, so this is empty for it. Empty rather than
  /// null because "the agent said nothing about it" is one thing, not two.
  final String note;

  int get total => items.length;

  int get doneCount => items
      .where((item) => item.state == AgentPlanItemState.completed)
      .length;

  /// The item the agent says it is on, or null when it says it is on none.
  ///
  /// The first, not the only: nothing in either CLI's schema stops two items
  /// being `in_progress`, and a real list on this machine has held two.
  AgentPlanItem? get current {
    for (final item in items) {
      if (item.state == AgentPlanItemState.inProgress) return item;
    }
    return null;
  }

  /// Every item is done. **The state that must look different from an
  /// abandoned list**, which is the whole question this feature answers.
  bool get isFinished => items.isNotEmpty && doneCount == items.length;

  /// The one line that identifies this plan, for a transcript row's subject.
  ///
  /// Bounded, because [AgentPlanItem.text] is not.
  String get headline {
    final progress = '$doneCount/$total done';
    final on = current?.text;
    if (on == null || on.isEmpty) return progress;
    final firstLine = on.split('\n').first;
    final short = firstLine.length <= _kHeadlineChars
        ? firstLine
        : '${firstLine.substring(0, _kHeadlineChars)}…';
    return '$progress · $short';
  }

  @override
  bool operator ==(Object other) {
    if (other is! AgentPlan) return false;
    if (other.note != note || other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(note, Object.hashAll(items));

  @override
  String toString() => 'AgentPlan($doneCount/$total)';
}

/// The most of a plan item that fits on one row beside the tool's name.
const int _kHeadlineChars = 72;

/// How an agent publishes the plan it keeps for itself.
enum AgentPlanStyle {
  /// Every write carries the **whole list**, so the newest one is the plan and
  /// nothing has to be folded. Measured for both shipped CLIs that have one —
  /// see [AgentPlanSupport.evidence].
  snapshot,

  /// A write carries only what changed, so a reader has to accumulate. **No
  /// agent here is declared this way**; it exists because the two answers need
  /// different readers and the difference must be recorded rather than assumed
  /// the day a third CLI arrives.
  delta,

  /// This agent publishes no plan we can read. **The default.**
  none,
}

/// Whether one agent publishes a plan of its own, and where to read it from.
///
/// Modelled exactly like [AgentForkSupport], [AgentMcpSupport] and
/// [AgentAttachmentSupport] — declared data on the descriptor, [evidence]
/// required, defaulting to the conservative answer — and read the same way:
/// nothing branches on an agent's *name* to decide whether it has a plan.
///
/// **Defaults to [AgentPlanStyle.none]**, and the asymmetry runs the same
/// direction as [AgentAttachmentSupport]'s. A plan we failed to find costs a
/// panel that says so; an *empty list* drawn for an agent that never keeps one
/// reads as "this agent has planned no work", which is a confident false
/// statement about somebody's running session — the exact thing §19 exists to
/// delete.
class AgentPlanSupport {
  /// This agent rewrites its whole list on every change, as [toolName]'s
  /// input. [itemsKey] holds the list; each entry's [textKey] holds the line
  /// and its [stateKey] holds one of [stateWords].
  const AgentPlanSupport.snapshotTool({
    required this.toolName,
    required this.itemsKey,
    required this.textKey,
    required this.stateKey,
    required this.stateWords,
    this.noteKey = '',
    required this.evidence,
  }) : style = AgentPlanStyle.snapshot,
       refusal = '';

  /// Nothing is known to publish. The default, and the answer for an agent
  /// whose record nobody has read.
  ///
  /// [refusal] is the sentence the panel shows in place of a list. It is the
  /// host's words because only the host has ever looked at this CLI's store.
  const AgentPlanSupport.none({this.refusal = ''})
    : style = AgentPlanStyle.none,
      toolName = '',
      itemsKey = '',
      textKey = '',
      stateKey = '',
      stateWords = const {},
      noteKey = '',
      evidence = '';

  final AgentPlanStyle style;

  /// The tool the agent calls to publish its plan. Empty when it publishes
  /// none.
  final String toolName;

  /// The key in that call's input holding the list.
  final String itemsKey;

  /// The key on one entry holding what the item says.
  final String textKey;

  /// The key on one entry holding its state.
  final String stateKey;

  /// The CLI's own state words → what they mean. **Verbatim**, so a CLI that
  /// renames one is a declaration change here and a visibly `unrecorded` item
  /// there, rather than a silently wrong count.
  final Map<String, AgentPlanItemState> stateWords;

  /// The key holding the agent's sentence about the plan, or empty when this
  /// agent writes none.
  final String noteKey;

  /// Where this was verified — the transcript and the count it was read off —
  /// so a future CLI version can be re-checked rather than trusted because it
  /// is written down.
  final String evidence;

  /// Why there is no plan to show, when there are words for it.
  final String refusal;

  bool get isSupported => style != AgentPlanStyle.none;

  /// **The plan [payload] states, or null when it states none.**
  ///
  /// Best-effort in the same way `readCliTranscript` is, and the failure
  /// direction is chosen rather than inherited: a shape this no longer
  /// understands yields **null**, which the fold reads as *nothing new*, so the
  /// plan already on screen survives a CLI that changed its schema. Returning
  /// an empty [AgentPlan] would overwrite a real list with "no work planned",
  /// which is worse than showing one that is a version behind and says its age.
  ///
  /// An empty [itemsKey] list is treated the same way, deliberately. It cannot
  /// be told apart from a shape we misread, and across 164 `TodoWrite` calls
  /// and 101 `update_plan` calls in the owner's stores **no agent has ever
  /// written one** — the smallest real list is a single item.
  ///
  /// [payload] is a decoded map (Claude Code puts its input there) or a JSON
  /// string holding one (Codex sends `arguments` as text). Both, because the
  /// two CLIs put the same thing in different envelopes and neither is worth a
  /// second reader.
  AgentPlan? planIn(Object? payload) {
    if (!isSupported) return null;
    final map = _asMap(payload);
    if (map == null) return null;
    final raw = map[itemsKey];
    if (raw is! List) return null;
    final items = <AgentPlanItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final text = entry[textKey];
      if (text is! String) continue;
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      final word = entry[stateKey];
      items.add(
        AgentPlanItem(
          text: trimmed,
          state: word is String
              ? (stateWords[word] ?? AgentPlanItemState.unrecorded)
              : AgentPlanItemState.unrecorded,
        ),
      );
    }
    if (items.isEmpty) return null;
    final note = noteKey.isEmpty ? null : map[noteKey];
    return AgentPlan(
      items: items,
      note: note is String ? note.trim() : '',
    );
  }

  /// [payload] as a map, decoding it first when it arrived as JSON text.
  static Map<Object?, Object?>? _asMap(Object? payload) {
    if (payload is Map) return payload;
    if (payload is! String || payload.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? decoded : null;
    } on FormatException {
      // A malformed argument string is a line we skip, not an empty plan.
      return null;
    }
  }
}

/// **Claude Code's own todo list**, as `TodoWrite` writes it.
///
/// Measured 2026-09-08 against `~/.claude/projects` on the owner's machine.
/// One session (`G--dev-godot-sampada-trails/e90749e9…jsonl`) holds **164**
/// `TodoWrite` calls, each an `assistant` line whose
/// `message.content[].tool_use.input` is `{"todos":[{"content","activeForm",
/// "status"}]}`. Lists ran 1–15 items; the three status words are the only
/// ones that appear.
///
/// **A snapshot, and this is the load-bearing measurement.** The `tool_result`
/// answering each call carries `toolUseResult.oldTodos` *and* `newTodos`, and
/// `newTodos` is the whole list every time — so the last call wins and nothing
/// is folded. Reading it as a delta would have been wrong in a way that only
/// shows up late: list sizes in that session go 15 → 4 → 11 and end at 1, so an
/// accumulating reader would draw items the agent had already dropped.
///
/// `activeForm` is deliberately not read. It is the same item in the present
/// participle ("Auditing existing template systems"), which is the CLI's own
/// spinner text rather than a second fact about the work.
const AgentPlanSupport kClaudeCodeTodoWrite = AgentPlanSupport.snapshotTool(
  toolName: 'TodoWrite',
  itemsKey: 'todos',
  textKey: 'content',
  stateKey: 'status',
  stateWords: {
    'pending': AgentPlanItemState.pending,
    'in_progress': AgentPlanItemState.inProgress,
    'completed': AgentPlanItemState.completed,
  },
  evidence:
      '164 TodoWrite tool_use calls in '
      'G--dev-godot-sampada-trails/e90749e9-4044-4cef-b7e0-916329ce4c92.jsonl, '
      'read 2026-09-08: input {"todos":[{content,activeForm,status}]}, sizes '
      '1-15, statuses pending/in_progress/completed; the answering '
      'tool_result carries oldTodos+newTodos, so each call is a full snapshot',
);

/// **Codex's own plan**, as `update_plan` writes it.
///
/// Measured 2026-09-08 against `~/.codex/sessions` (76 rollouts on Windows,
/// 30 under WSL): **101** calls, every one a `payload.type == "function_call"`
/// named `update_plan` whose `arguments` is a **JSON string** holding
/// `{"explanation"?, "plan":[{"step","status"}]}`. Lists ran 2–7 items. The
/// call is answered with the string `"Plan updated"` and nothing else, so the
/// input is the only place the plan exists.
///
/// A snapshot for the same reason Claude's is: the whole `plan` array is
/// resent, and item statuses flip within it between calls.
///
/// Note the vocabulary is **not** symmetric with Claude Code's even though the
/// three state words happen to be identical: the list is `plan`, not `todos`,
/// and an item's line is `step`, not `content`. Assuming symmetry would have
/// read every Codex plan as empty.
const AgentPlanSupport kCodexUpdatePlan = AgentPlanSupport.snapshotTool(
  toolName: 'update_plan',
  itemsKey: 'plan',
  textKey: 'step',
  stateKey: 'status',
  stateWords: {
    'pending': AgentPlanItemState.pending,
    'in_progress': AgentPlanItemState.inProgress,
    'completed': AgentPlanItemState.completed,
  },
  noteKey: 'explanation',
  evidence:
      '101 update_plan function_call payloads across 106 rollouts in '
      '~/.codex/sessions, read 2026-09-08: arguments is a JSON string '
      '{explanation?, plan:[{step,status}]}, sizes 2-7, statuses '
      'pending/in_progress/completed; the output is only "Plan updated"',
);

/// Every plan tool this app can read, by the name the CLI calls it.
///
/// Keyed on the **tool's own name** rather than on the session's agent, because
/// the transcript reader is handed a CLI id and not a descriptor — and each
/// declared name belongs to exactly one CLI. A tool of some other agent's that
/// happened to share a name would still have to match the whole shape above to
/// produce anything.
final Map<String, AgentPlanSupport> agentPlanToolsByName = {
  for (final support in const [kClaudeCodeTodoWrite, kCodexUpdatePlan])
    support.toolName: support,
};

/// The plan a call to [toolName] with [payload] publishes, or null when that
/// call is not a plan tool or states no plan.
///
/// The one seam the transcript reader uses, so a tool row costs a single map
/// lookup unless it really is one of the two.
AgentPlan? agentPlanForToolCall(String toolName, Object? payload) =>
    agentPlanToolsByName[toolName]?.planIn(payload);
