/// The document one agent is handed when it takes over another's work.
/// Provenance is never erased: the recap is quoted, never model-summarised.
library;

/// Codex's own compaction prompt, quoted verbatim from the `codex.exe` 0.153.4
/// binary (2026-09-09): a paraphrase would be a new prompt nobody has run.
const String kSourceBriefRequest =
    'You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff '
    'summary for another LLM that will resume the task.\n'
    '- Current progress and key decisions made\n'
    '- Important context, constraints, or user preferences\n'
    '- What remains to be done (clear next steps)\n'
    '- Any critical data, examples, or references needed to continue\n'
    'Be concise, structured, and focused on helping the next LLM seamlessly '
    'continue the work.';

/// The brief the source agent wrote, or why there is none. Two states: asked
/// and unanswered gets a section; nobody asking leaves it null.
class HandoffSourceBrief {
  /// What the agent wrote, in its own words. Quoted, never edited.
  const HandoffSourceBrief.written(String this.text) : notWritten = null;

  /// Why there is no brief, in words the reader can act on. Never a bare
  /// "failed": "stopped for a person" and "had not answered yet" differ.
  const HandoffSourceBrief.notWritten(String this.notWritten) : text = null;

  final String? text;
  final String? notWritten;

  bool get wasWritten => text != null;
}

/// One changed file, as the packet states it — a local shape rather than git's
/// `FileChange`, so the packet renders and tests without a repository.
class HandoffChange {
  const HandoffChange({
    required this.path,
    required this.state,
    this.originalPath,
  });

  /// Path relative to the repository root.
  final String path;

  /// Plain words for what happened to it: `modified`, `added`, `deleted`,
  /// `renamed`, `untracked`.
  final String state;

  /// For a rename, where it came from.
  final String? originalPath;

  @override
  bool operator ==(Object other) =>
      other is HandoffChange &&
      other.path == path &&
      other.state == state &&
      other.originalPath == originalPath;

  @override
  int get hashCode => Object.hash(path, state, originalPath);
}

/// One quoted turn of the conversation being handed over.
class HandoffTurn {
  const HandoffTurn({required this.speaker, required this.text});

  /// Who said it, already resolved to something a reader recognises. Never
  /// "assistant": the packet is read by a second assistant.
  final String speaker;

  final String text;

  @override
  bool operator ==(Object other) =>
      other is HandoffTurn && other.speaker == speaker && other.text == text;

  @override
  int get hashCode => Object.hash(speaker, text);
}

/// One recorded decision, as the packet states it — a local shape so the packet
/// renders without a database. The pointer to the act is printed, never followed.
class HandoffDecision {
  const HandoffDecision({
    required this.kind,
    required this.summary,
    this.detail,
    this.decidedBy,
    this.origin,
    this.originId,
    this.recordedAt,
  });

  /// Plain words for what sort of decision this is: `Approach rejected`,
  /// `Verification verdict`.
  final String kind;

  /// The decision in the words of whoever made it. Quoted, never paraphrased.
  final String summary;

  final String? detail;

  /// Who decided — "the user", or an agent's display name. Null renders as
  /// **"not recorded"**, never as an omitted attribution.
  final String? decidedBy;

  /// The act that produced it, as a noun phrase: `verification run`.
  final String? origin;

  /// That act's own identifier, when it left a record. Null for an act that
  /// did not, such as an approval prompt on another program's screen.
  final String? originId;

  final DateTime? recordedAt;

  @override
  bool operator ==(Object other) =>
      other is HandoffDecision &&
      other.kind == kind &&
      other.summary == summary &&
      other.detail == detail &&
      other.decidedBy == decidedBy &&
      other.origin == origin &&
      other.originId == originId &&
      other.recordedAt == recordedAt;

  @override
  int get hashCode => Object.hash(
    kind,
    summary,
    detail,
    decidedBy,
    origin,
    originId,
    recordedAt,
  );
}

/// Who may write one section of the packet, and who may only read it. Per
/// section, because a quoted recap has no editors and a dead-end list has one.
class HandoffSectionOwner {
  const HandoffSectionOwner(this.owner, {this.editors = const []});

  /// Whose section it is. Never empty and never omitted.
  final String owner;

  /// Who else may write in it. Empty means nobody.
  final List<String> editors;

  String get line => editors.isEmpty
      ? '_Owner: $owner. No editors — if you disagree with something here, say '
            'so; do not rewrite it._'
      : '_Owner: $owner. May edit: ${editors.join(', ')} — add under your own '
            'name rather than replacing what is here._';
}

/// One thing the packet asserts, and what backs it. Null evidence renders as
/// "not checked yet": an unqualified claim is read as a checked one.
class HandoffClaim {
  const HandoffClaim({
    required this.statement,
    this.evidence,
    this.attributedTo,
  });

  final String statement;

  /// A `path:line`, a command and its output, or null for "not checked yet".
  final String? evidence;

  /// Who said it. Null renders as "not recorded", never as an omitted
  /// attribution.
  final String? attributedTo;

  /// What the packet prints for [evidence]. Never empty.
  String get evidenceLine {
    final given = evidence?.trim();
    return given == null || given.isEmpty ? 'not checked yet' : given;
  }

  @override
  bool operator ==(Object other) =>
      other is HandoffClaim &&
      other.statement == statement &&
      other.evidence == evidence &&
      other.attributedTo == attributedTo;

  @override
  int get hashCode => Object.hash(statement, evidence, attributedTo);
}

/// Everything the receiving agent is told, and the renderer that says it. Null
/// renders as a sentence admitting the gap, never as an omitted section.
class HandoffPacket {
  const HandoffPacket({
    required this.sourceAgentName,
    required this.targetAgentName,
    required this.sourceTitle,
    required this.sourceSessionId,
    required this.instruction,
    this.workingDirectory,
    this.branch,
    this.commitsAhead,
    this.baseBranch,
    this.changes,
    this.recap = const [],
    this.omittedTurns = 0,
    this.decisions = const [],
    this.omittedDecisions = 0,
    this.unresolvedTasks = const [],
    this.deadEnds,
    this.sourceBrief,
    this.isFork = false,
  });

  /// The agent that held the conversation.
  final String sourceAgentName;

  /// The agent about to receive it.
  final String targetAgentName;

  final String sourceTitle;
  final String sourceSessionId;

  /// What the user actually wants done next. The last thing in the document,
  /// because it is the only part that is an instruction rather than context.
  final String instruction;

  final String? workingDirectory;
  final String? branch;
  final int? commitsAhead;
  final String? baseBranch;

  /// Changed files, or **null for "git could not be asked"**. An empty list is
  /// the positive answer "the working tree is clean".
  final List<HandoffChange>? changes;

  /// The tail of the conversation, oldest first.
  final List<HandoffTurn> recap;

  /// How many earlier turns were left out, so the receiving agent knows the
  /// recap is a tail and not the whole thing.
  final int omittedTurns;

  /// The session's decision record, oldest first, or **null for "could not be
  /// read"**. Unlike [changes], empty is not an answer — it renders the same.
  final List<HandoffDecision>? decisions;

  /// How many older decisions were left out. Effectively always zero — they are
  /// charged to the budget before the recap — but reported, not assumed.
  final int omittedDecisions;

  /// Whatever the user typed as still-open work. Free text, one item per line,
  /// passed through unedited — Karmashala has no idea which of these are done.
  final List<String> unresolvedTasks;
  /// Approaches already ruled out, or **null for "could not be read"**. Read
  /// like [decisions]: an empty list is not "nothing was ruled out".
  final List<HandoffClaim>? deadEnds;

  /// The source agent's own handoff summary, or **null when nobody asked**. The
  /// one part written by a model, and it stands beside the quotes, not instead.
  final HandoffSourceBrief? sourceBrief;

  /// Whether this packet stands in for a fork the CLI could not perform.
  /// Changes only the framing — a *branch* of the conversation, not a takeover.
  final bool isFork;

  /// The packet as Markdown, which is what the agent receives as its first
  /// message.
  String render() {
    final out = StringBuffer();
    final kind = isFork ? 'Forked' : 'Handed off';
    out.writeln('# $kind from $sourceAgentName');
    out.writeln();
    out.writeln(_provenance());
    out.writeln();
    out.writeln(_howToReadThis());
    out.writeln();

    out.writeln('## Where this came from');
    out.writeln();
    out.writeln('- **Previous agent:** $sourceAgentName');
    out.writeln('- **Session:** "$sourceTitle" (`$sourceSessionId`)');
    out.writeln('- **You are:** $targetAgentName');
    if (workingDirectory != null) {
      out.writeln('- **Working directory:** `$workingDirectory`');
    }
    out.writeln('- **Branch:** ${_branchLine()}');
    out.writeln();

    if (sourceBrief != null) {
      out.writeln('## In $sourceAgentName\'s own words');
      out.writeln();
      // No editors: it is a quotation, and an edited quotation is not one.
      out.writeln(HandoffSectionOwner(sourceAgentName).line);
      out.writeln();
      out.writeln(_sourceBriefSection());
      out.writeln();
    }

    out.writeln('## Files changed in the working tree');
    out.writeln();
    out.writeln(HandoffSectionOwner(_readFrom).line);
    out.writeln();
    out.writeln(_changesSection());
    out.writeln();

    // Ahead of everything else that was recorded, because it is the section a
    // reader most needs before they start work rather than after it.
    out.writeln('## Don\'t do');
    out.writeln();
    out.writeln(
      HandoffSectionOwner(
        sourceAgentName,
        editors: [targetAgentName],
      ).line,
    );
    out.writeln();
    out.writeln(_deadEndsSection());
    out.writeln();

    // Ahead of the recap because the recap is what gets truncated, and the
    // decisions are exactly what a long session's truncated turns were carrying.
    out.writeln('## Decisions on record');
    out.writeln();
    out.writeln(
      HandoffSectionOwner(
        '$sourceAgentName and the user',
        editors: [targetAgentName],
      ).line,
    );
    out.writeln();
    out.writeln(_decisionsSection());
    out.writeln();

    out.writeln('## Conversation so far');
    out.writeln();
    // No editors: quoted evidence, and an edited quotation is not evidence.
    out.writeln(HandoffSectionOwner('$sourceAgentName and the user').line);
    out.writeln();
    out.writeln(_recapSection());
    out.writeln();

    if (unresolvedTasks.isNotEmpty) {
      out.writeln('## Still open, per the user');
      out.writeln();
      out.writeln(const HandoffSectionOwner('the user').line);
      out.writeln();
      for (final task in unresolvedTasks) {
        out.writeln('- [ ] $task');
      }
      out.writeln();
    }

    out.writeln('## What you are being asked to do');
    out.writeln();
    out.writeln(const HandoffSectionOwner('the user').line);
    out.writeln();
    out.writeln(instruction.trim());
    return out.toString().trimRight();
  }

  /// Who read the working tree. Named rather than left blank, because "the
  /// files say so" and "an agent said the files say so" are different claims.
  static const String _readFrom = 'Karmashala, read from git';

  /// The two rules that keep three models from quietly overwriting each other,
  /// stated once and applied per section below.
  String _howToReadThis() =>
      '**Evidence.** Every claim here carries a `path:line`, a command and what '
      'it printed, or the words "not checked yet". **A previous packet is a '
      'claim, not evidence** — including this one. Where anything below '
      'disagrees with the files in front of you, **the files win**, and the '
      'mismatch is worth reporting rather than quietly correcting: it means '
      'something changed that nobody wrote down.\n\n'
      '**Ownership.** Each section names its owner and who may edit it. More '
      'than one model writes into a document like this, so add under your own '
      'name rather than rewriting somebody else\'s paragraph — and if you '
      'think a section is wrong, say why beside it.';

  String _sourceBriefSection() {
    final brief = sourceBrief!;
    final text = brief.text;
    if (text == null) {
      return '$sourceAgentName was asked to write this and did not: '
          '${brief.notWritten}\n\n'
          'Nothing else in this packet depends on it — the rest is assembled '
          'from files and quoted from the transcript, exactly as it would '
          'have been.';
    }
    final out = StringBuffer()
      ..writeln(
        '_$sourceAgentName wrote this when the handoff was prepared, in '
        'answer to a request for a context-checkpoint handoff summary. It is '
        'that agent\'s account of its own work and nobody has checked it: '
        'the evidence rule above applies to every line of it, and the '
        'verbatim quotes further down are what to check it against._',
      )
      ..writeln();
    for (final line in _lines(text)) {
      out.writeln('> $line');
    }
    return out.toString().trimRight();
  }

  String _deadEndsSection() {
    final ruled = deadEnds;
    if (ruled == null) {
      return 'Could not be read — this session\'s decision record did not '
          'answer. Ask the user what has already been tried before spending a '
          'turn re-deriving it.';
    }
    if (ruled.isEmpty) {
      // Never "nothing was ruled out": the record is written by explicit acts,
      // so an empty one means nobody wrote anything down.
      return 'Nothing was recorded as ruled out. That is not the same as '
          '"nothing was ruled out": this list is written only when somebody '
          'records a rejected approach deliberately. Ask before assuming an '
          'approach is untried.';
    }
    final out = StringBuffer();
    for (final claim in ruled) {
      out.writeln('- **${claim.statement.trim()}**');
      out.writeln('  - said by: ${claim.attributedTo ?? 'not recorded'}');
      out.writeln('  - evidence: ${claim.evidenceLine}');
    }
    return out.toString().trimRight();
  }

  String _provenance() => isFork
      ? 'This conversation is a **branch** of an existing $sourceAgentName '
            'session. Everything below happened in that session, before the '
            'branch point; it is quoted verbatim and was not written by you. '
            'The original session still exists and is unchanged — you are not '
            'continuing it, you are continuing *from* it.'
      : 'You are taking over work that **$sourceAgentName** was doing in this '
            'same directory. Everything below is quoted from that session; it '
            'is not your own history and none of it has been rewritten to read '
            'as though you produced it. Treat the code and decisions described '
            'as things you are inheriting and can inspect, not as things you '
            'remember doing.'
            // Codex's own receiving-side framing, minus its claim that the
            // reader also has the other model's tool state — here that is false.
            '\n\nAnother model started this and has stopped. Build on what it '
            'did rather than repeating it — and where you cannot tell whether '
            'something was done, look, do not assume either way.';

  String _branchLine() {
    if (branch == null) return 'unknown (git could not be asked)';
    final ahead = commitsAhead;
    if (ahead == null || baseBranch == null) return '`$branch`';
    final commits = ahead == 1 ? 'commit' : 'commits';
    return '`$branch` — $ahead $commits ahead of `$baseBranch`';
  }

  String _changesSection() {
    final files = changes;
    if (files == null) {
      return 'Could not be read — git did not answer. Run `git status` '
          'yourself before assuming the tree is clean.';
    }
    if (files.isEmpty) {
      return 'None: the working tree is clean.';
    }
    final out = StringBuffer();
    for (final file in files) {
      final from = file.originalPath;
      out.writeln(
        from == null
            ? '- `${file.path}` — ${file.state}'
            : '- `${file.path}` — ${file.state} from `$from`',
      );
    }
    return out.toString().trimRight();
  }

  String _decisionsSection() {
    final recorded = decisions;
    if (recorded == null) {
      return 'Not recorded — this session\'s decision record could not be '
          'read. Ask the user what was decided rather than guessing.';
    }
    if (recorded.isEmpty) {
      // Never "none": an empty record is a gap in the recording, and reading it
      // as "nothing was decided" tells the next agent it is unconstrained.
      return 'Not recorded: nothing was written to this session\'s decision '
          'record.\n\n'
          'That is not the same as "nothing was decided". The record is only '
          'written by explicit acts — an approval answered, a verification '
          'finished, a checkpoint labelled, an agent recording a decision '
          'deliberately — so an empty one means nobody wrote anything down. '
          'Ask the user what was settled rather than assuming nothing was.';
    }

    final out = StringBuffer();
    final shown = recorded.length;
    if (omittedDecisions > 0) {
      final total = shown + omittedDecisions;
      out.writeln(
        '_The last $shown of $total decisions, oldest first. The earlier '
        '$omittedDecisions are not included — ask rather than assume what was '
        'in them._',
      );
    } else {
      out.writeln(
        '_$shown decision${shown == 1 ? '' : 's'}, oldest first, each written '
        'at the moment it was made. Nothing here was inferred from what was '
        'said._',
      );
    }
    out.writeln();
    for (final decision in recorded) {
      out.writeln('**${decision.kind}** — ${_attribution(decision)}');
      out.writeln();
      for (final line in _lines(decision.summary)) {
        out.writeln('> $line');
      }
      final detail = decision.detail;
      if (detail != null && detail.trim().isNotEmpty) {
        out.writeln('>');
        for (final line in _lines(detail)) {
          out.writeln('> $line');
        }
      }
      out.writeln();
    }
    return out.toString().trimRight();
  }

  /// Who decided, when, and which act wrote it down. Every part says "not
  /// recorded" rather than disappearing, which would read as unattributed fact.
  String _attribution(HandoffDecision decision) {
    final parts = <String>[
      'decided by ${decision.decidedBy ?? 'not recorded'}',
    ];
    final at = decision.recordedAt;
    parts.add(at == null ? 'time not recorded' : _stamp(at));
    final origin = decision.origin;
    parts.add(
      origin == null
          ? 'source not recorded'
          : decision.originId == null
          ? 'from $origin'
          : 'from $origin `${decision.originId}`',
    );
    return parts.join(', ');
  }

  static List<String> _lines(String text) =>
      text.replaceAll('\r\n', '\n').trim().split('\n');

  /// `2026-08-31 12:05Z` — minutes and UTC, which is as much precision as a
  /// reader can do anything with and no more than the record actually knows.
  static String _stamp(DateTime at) {
    final utc = at.toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}Z';
  }

  String _recapSection() {
    if (recap.isEmpty) {
      return omittedTurns > 0
          ? 'The transcript could not be quoted here, though it has '
                '$omittedTurns earlier turns. Ask the user what was decided '
                'rather than guessing.'
          : 'Nothing was said in that session yet.';
    }
    final out = StringBuffer();
    final shown = recap.length;
    if (omittedTurns > 0) {
      final total = shown + omittedTurns;
      out.writeln(
        '_The last $shown of $total turns, oldest first. The earlier '
        '$omittedTurns are not included — ask rather than assume what was in '
        'them._',
      );
    } else {
      out.writeln('_All $shown turns, oldest first, quoted verbatim._');
    }
    out.writeln();
    for (final turn in recap) {
      out.writeln('**${turn.speaker}:**');
      out.writeln();
      for (final line in turn.text.replaceAll('\r\n', '\n').split('\n')) {
        out.writeln('> $line');
      }
      out.writeln();
    }
    return out.toString().trimRight();
  }
}

/// How much of a conversation a packet carries. A budget rather than a turn
/// count: turns are uneven, and the agent pays for every character on turn one.
class HandoffRecapBudget {
  const HandoffRecapBudget({
    this.maxCharacters = 6000,
    this.maxTurns = 24,
    this.maxCharactersPerTurn = 1200,
  });

  final int maxCharacters;
  final int maxTurns;
  final int maxCharactersPerTurn;

  /// The same budget with [spent] characters already gone — how the decision
  /// record is paid for, making the *recap* the thing that shrinks.
  HandoffRecapBudget reducedBy(int spent) => HandoffRecapBudget(
    maxCharacters: maxCharacters - spent < 0 ? 0 : maxCharacters - spent,
    maxTurns: maxTurns,
    maxCharactersPerTurn: maxCharactersPerTurn,
  );
}

/// How much of a decision record a packet carries. A backstop against a
/// pathological session: in ordinary use the whole record travels.
class HandoffDecisionBudget {
  const HandoffDecisionBudget({
    this.maxCharacters = 4000,
    this.maxDecisions = 40,
    this.maxCharactersPerDecision = 400,
  });

  final int maxCharacters;
  final int maxDecisions;
  final int maxCharactersPerDecision;
}

/// Trims [decisions] (oldest first) to fit [budget], newest kept, reporting the
/// drop and the cost. Over-long ones are truncated *in the middle*.
({List<HandoffDecision> decisions, int omitted, int cost}) trimDecisions(
  List<HandoffDecision> decisions, [
  HandoffDecisionBudget budget = const HandoffDecisionBudget(),
]) {
  final kept = <HandoffDecision>[];
  var used = 0;
  for (var i = decisions.length - 1; i >= 0; i--) {
    if (kept.length >= budget.maxDecisions) break;
    final decision = decisions[i];
    final summary = _truncateMiddle(
      decision.summary,
      budget.maxCharactersPerDecision,
    );
    final detail = decision.detail == null
        ? null
        : _truncateMiddle(decision.detail!, budget.maxCharactersPerDecision);
    final cost =
        summary.length +
        (detail?.length ?? 0) +
        decision.kind.length +
        (decision.decidedBy?.length ?? 0) +
        (decision.origin?.length ?? 0);
    if (kept.isNotEmpty && used + cost > budget.maxCharacters) break;
    kept.add(
      HandoffDecision(
        kind: decision.kind,
        summary: summary,
        detail: detail,
        decidedBy: decision.decidedBy,
        origin: decision.origin,
        originId: decision.originId,
        recordedAt: decision.recordedAt,
      ),
    );
    used += cost;
  }
  return (
    decisions: kept.reversed.toList(),
    omitted: decisions.length - kept.length,
    cost: used,
  );
}

/// Trims [turns] (oldest first) to fit [budget], newest kept. Truncated *in the
/// middle*: a pasted log has its outcome at the bottom.
({List<HandoffTurn> turns, int omitted}) trimRecap(
  List<HandoffTurn> turns, [
  HandoffRecapBudget budget = const HandoffRecapBudget(),
]) {
  final kept = <HandoffTurn>[];
  var used = 0;
  for (var i = turns.length - 1; i >= 0; i--) {
    if (kept.length >= budget.maxTurns) break;
    final turn = turns[i];
    final text = _truncateMiddle(turn.text, budget.maxCharactersPerTurn);
    final cost = text.length + turn.speaker.length;
    // Always keep at least the final turn, whatever it costs: an empty recap is
    // strictly worse than being over budget by one message.
    if (kept.isNotEmpty && used + cost > budget.maxCharacters) break;
    kept.add(HandoffTurn(speaker: turn.speaker, text: text));
    used += cost;
  }
  return (turns: kept.reversed.toList(), omitted: turns.length - kept.length);
}

String _truncateMiddle(String text, int limit) {
  if (text.length <= limit) return text;
  const marker = '\n\n[… trimmed for the handoff …]\n\n';
  final half = (limit - marker.length) ~/ 2;
  if (half <= 0) return text.substring(0, limit);
  return '${text.substring(0, half)}$marker'
      '${text.substring(text.length - half)}';
}
