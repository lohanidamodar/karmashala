/// The document one agent is handed when it takes over another's work.
///
/// ## The one rule
///
/// **Provenance is never erased.** The packet opens by saying which agent held
/// the conversation, and the recap is quoted, attributed and labelled as an
/// excerpt. It is never rewritten into a first-person account that reads as if
/// the receiving agent had done the work.
///
/// That is the whole point of the feature as MonoCode framed it and as the
/// comparison document asked for it — *"continue in a new provider without
/// rewriting history as if one agent produced it all"* — and it is not
/// cosmetic. An agent that believes it wrote code it has never seen will
/// describe that code from memory it does not have. The packet is the moment
/// where that belief is either created or prevented.
///
/// ## Why the recap is quoted rather than summarised
///
/// Because a summary would have to be *written by a model*, and there is no
/// model in this path — the packet is assembled from files while the user waits,
/// before anything is launched. Writing one would mean either spending a turn of
/// the user's quota on the very agent whose quota may be why they are handing
/// off, or having Karmashala paraphrase a conversation it does not understand.
/// Both produce a confident recap that can be wrong in ways the receiving agent
/// cannot detect.
///
/// A verbatim tail is worse prose and better evidence: it is either right or
/// visibly incomplete, and [HandoffPacket.render] says exactly how much was left
/// out. That honesty is available to the reader; a paraphrase's errors are not.
library;

/// What the source session is asked for when the user wants the brief in the
/// agent's own words.
///
/// **Codex's own compaction prompt**, and it is quoted rather than reworded
/// for the reason the packet quotes everything else: it is a prompt somebody
/// shipped and tuned for exactly this job, and a paraphrase of it is a new
/// prompt nobody has run. Read verbatim out of the `codex.exe` 0.153.4
/// binary on 2026-09-09, beside `core\src\compact.rs`.
const String kSourceBriefRequest =
    'You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff '
    'summary for another LLM that will resume the task.\n'
    '- Current progress and key decisions made\n'
    '- Important context, constraints, or user preferences\n'
    '- What remains to be done (clear next steps)\n'
    '- Any critical data, examples, or references needed to continue\n'
    'Be concise, structured, and focused on helping the next LLM seamlessly '
    'continue the work.';

/// The brief the source agent wrote, or why there is none.
///
/// Two states and no third. A brief that was asked for and not answered is
/// **not** the same as one nobody asked for: the first is a fact about that
/// session and gets a section saying so, the second leaves the packet exactly
/// as it was before any of this existed, which is what declining has to mean.
/// [HandoffPacket.sourceBrief] is null for the second.
class HandoffSourceBrief {
  /// What the agent wrote, in its own words. Quoted, never edited.
  const HandoffSourceBrief.written(String this.text) : notWritten = null;

  /// Why there is no brief, in words the reader can act on. Never a bare
  /// "failed": the two that matter — the agent is stopped for a person, and
  /// the agent had not answered yet — need opposite responses.
  const HandoffSourceBrief.notWritten(String this.notWritten) : text = null;

  final String? text;
  final String? notWritten;

  bool get wasWritten => text != null;
}

/// One changed file, as the packet states it.
///
/// A local shape rather than `git`'s `FileChange` so the packet — the thing with
/// all the wording in it — can be rendered and tested without a repository. The
/// builder maps one to the other in one place.
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

  /// Who said it, already resolved to something a reader recognises — the
  /// user, or the *source agent's display name*. Never "assistant": the packet
  /// is read by a second assistant, and an unqualified "assistant" is exactly
  /// the confusion this document exists to prevent.
  final String speaker;

  final String text;

  @override
  bool operator ==(Object other) =>
      other is HandoffTurn && other.speaker == speaker && other.text == text;

  @override
  int get hashCode => Object.hash(speaker, text);
}

/// One recorded decision, as the packet states it.
///
/// A local shape rather than `DecisionRecord`, for the same reason
/// [HandoffChange] is not `FileChange`: the packet is the thing with all the
/// wording in it, and it must be renderable and testable without a database.
/// The builder maps one to the other in one place.
///
/// Everything here is already words. [kind] is the heading, [decidedBy] is the
/// attribution, [origin] and [originId] are the pointer back to the act — and
/// **the pointer is printed, never followed**, so a decision whose verification
/// run has been pruned reads exactly as well as one whose run is still there.
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

  /// More of those words, when there were more.
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

/// Who may write one section of the packet, and who may only read it.
///
/// A handoff is three models writing into one document — the agent that held
/// the conversation, the person, and the agent taking it over — and until now
/// nothing said which of them owned what. An unowned section is one all three
/// assume is theirs, and the loss is silent: a paragraph is rewritten and the
/// version that said something inconvenient is simply gone.
///
/// Stated per section rather than once at the top, because the answer differs
/// per section. A quoted recap has **no** editors — it is evidence, and an
/// edited quotation is not. A dead-end list has one, because adding to it is
/// exactly what the receiving agent is for.
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

/// One thing the packet asserts, and what backs it.
///
/// The evidence rule in a type: a claim either carries a `path:line`, a command
/// and what it printed, or the words **"not checked yet"**. Null renders as the
/// third rather than as an omitted qualifier, because an unqualified claim is
/// read as a checked one — which is how a guess made forty turns ago becomes a
/// constraint the next agent works around.
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
  /// attribution — the same rule [HandoffDecision.decidedBy] holds.
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

/// Everything the receiving agent is told, and the renderer that says it.
///
/// Every field that could be unknown is nullable, and **null renders as a
/// sentence admitting it** rather than as an omitted section. A missing "Files
/// changed" heading reads as "nothing changed"; "could not be read" reads as
/// what it is. The distinction matters most in the case that motivates a
/// handoff — a long session with real work in the tree.
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

  /// The session's decision record, oldest first, or **null for "it could not
  /// be read"**.
  ///
  /// An empty list does *not* mean "nothing was decided", and this is the one
  /// place the packet deliberately breaks the reading it uses for [changes]. An
  /// empty `changes` is a positive answer — git was asked and the tree is
  /// clean. An empty decision record is not an answer at all: the record is
  /// written only by explicit acts, so an empty one means nobody wrote anything
  /// down. Both null and empty therefore render as **"not recorded"**, in
  /// different words, and neither ever renders as "none".
  final List<HandoffDecision>? decisions;

  /// How many older decisions were left out. Effectively always zero — the
  /// decisions are charged to the budget *before* the recap precisely so that
  /// the recap is what gives — but reported rather than assumed.
  final int omittedDecisions;

  /// Whatever the user typed as still-open work. Free text, one item per line,
  /// passed through unedited — Karmashala has no idea which of these are done.
  final List<String> unresolvedTasks;

  /// Approaches already ruled out, or **null for "the record could not be
  /// read"**.
  ///
  /// The knowledge that costs most to re-derive: an agent that does not know an
  /// approach was tried will try it, spend the turns, and reach the same wall.
  /// Read the same way [decisions] is — an empty list is *not* "nothing was
  /// ruled out", because the record is only written by explicit acts.
  final List<HandoffClaim>? deadEnds;

  /// The source agent's own handoff summary, when the user asked for one, or
  /// **null when nobody asked** — which leaves this packet exactly as it was
  /// before the feature existed.
  ///
  /// The one part of the document written by a model, and the whole of the
  /// class comment's argument above still applies to it: a summary can be
  /// confidently wrong in ways the receiving agent cannot detect. What makes
  /// it defensible here and not as a replacement for the recap is that it is
  /// **attributed, optional, and beside the quotes rather than instead of
  /// them** — the verbatim tail is still there to check it against.
  final HandoffSourceBrief? sourceBrief;

  /// Whether this packet is standing in for a fork the CLI could not perform.
  /// Changes only the framing, never the contents: the receiving agent is told
  /// it is continuing a *branch* of the conversation rather than taking it over.
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

    // Ahead of the recap, and not by taste: the recap is the part that gets
    // truncated, and the decisions are exactly what a long session's truncated
    // turns were carrying. Putting them first is what stops the packet losing
    // them again.
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
    // No editors, and this is the section that most needs saying so: it is
    // quoted evidence, and an edited quotation is not evidence any more.
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
      // Never "nothing was ruled out". The record is written by explicit acts,
      // so an empty one means nobody wrote anything down — and an agent that
      // reads it as "the field is open" will re-run the experiment that failed.
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
            // Codex's own receiving-side framing, in this document's terms.
            // Its wording — "another language model started to solve this
            // problem … build on the work that has already been done and
            // avoid duplicating work" — is the half worth taking; the half
            // that is not is its claim that the reader also has the other
            // model's tool state, which here would be false.
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
      // Never "none". An empty record is a gap in the *recording*, and reading
      // it as "nothing was decided" is the one wrong conclusion available
      // here — it would tell an agent taking over a forty-turn session that it
      // is starting from an unconstrained position.
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

  /// Who decided, when, and which act wrote it down.
  ///
  /// Every part says "not recorded" rather than disappearing. An omitted
  /// attribution reads as an unattributed *fact*, which is exactly how a
  /// constraint an agent invented for itself gets mistaken for one the user
  /// imposed.
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

/// How much of a conversation a packet carries.
///
/// A budget rather than a turn count, because turns are wildly uneven: twenty
/// one-line exchanges and one pasted stack trace are the same "20 messages" and
/// nothing like the same prompt. The receiving agent pays for every character
/// of this as input on its very first turn, in the situation where the user is
/// most likely to be handing off *because* the previous agent ran out of quota.
class HandoffRecapBudget {
  const HandoffRecapBudget({
    this.maxCharacters = 6000,
    this.maxTurns = 24,
    this.maxCharactersPerTurn = 1200,
  });

  final int maxCharacters;
  final int maxTurns;
  final int maxCharactersPerTurn;

  /// The same budget with [spent] characters already gone.
  ///
  /// This is how the decision record is paid for. The packet has one size, the
  /// receiving agent pays for all of it on its first turn, and something has to
  /// give when a session has both a long conversation and a lot of decisions.
  /// Charging the decisions first and handing the remainder here makes the
  /// *recap* the thing that shrinks — which is the trade this feature exists to
  /// make, because a quoted turn is recoverable from the transcript and a
  /// decision forty turns back is not.
  ///
  /// Floors at zero rather than going negative; `trimRecap` always keeps the
  /// final turn, so a fully spent budget still quotes the last thing said.
  HandoffRecapBudget reducedBy(int spent) => HandoffRecapBudget(
    maxCharacters: maxCharacters - spent < 0 ? 0 : maxCharacters - spent,
    maxTurns: maxTurns,
    maxCharactersPerTurn: maxCharactersPerTurn,
  );
}

/// How much of a decision record a packet carries.
///
/// Generous on purpose, and generous in a different way from the recap's
/// budget. Decisions are written only by explicit acts, so there are tens of
/// them where there are hundreds of turns, and each is a sentence rather than a
/// pasted log. The caps here are a backstop against a pathological session, not
/// a routine trim: in ordinary use nothing is dropped and the whole record
/// travels.
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

/// Trims [decisions] (oldest first) to fit [budget], keeping the **most
/// recent**, and reports how many were dropped and what the rest cost.
///
/// [cost] is what the caller subtracts from the recap's budget. Measured from
/// the text that will actually be rendered rather than estimated, because an
/// estimate that runs low is a packet over its size in exactly the case — a
/// long session — where the size was the reason for handing off.
///
/// An over-long decision is truncated *in the middle*, like a turn: a decision
/// with a rationale attached has the conclusion at one end and the reason at
/// the other, and cutting either end reliably loses one of them.
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

/// Trims [turns] (oldest first) to fit [budget], keeping the **most recent**,
/// and reports how many were dropped.
///
/// Recency wins because the end of a conversation is where the current state
/// is: what was just tried, what failed, what the file looks like now. The
/// beginning is where the original request is, and the user is about to restate
/// that themselves as the instruction.
///
/// An over-long single turn is truncated *in the middle* rather than at the end.
/// A tool result or a pasted log has its outcome at the bottom, and tail-only
/// truncation reliably keeps the least useful half.
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
    // Always keep at least the final turn, whatever it costs: a packet whose
    // recap is empty because one message was enormous is strictly worse than
    // one that is over budget by a single message.
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
