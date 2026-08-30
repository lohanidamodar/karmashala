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
/// off, or having Chitragupta paraphrase a conversation it does not understand.
/// Both produce a confident recap that can be wrong in ways the receiving agent
/// cannot detect.
///
/// A verbatim tail is worse prose and better evidence: it is either right or
/// visibly incomplete, and [HandoffPacket.render] says exactly how much was left
/// out. That honesty is available to the reader; a paraphrase's errors are not.
library;

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
    this.unresolvedTasks = const [],
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

  /// Whatever the user typed as still-open work. Free text, one item per line,
  /// passed through unedited — Chitragupta has no idea which of these are done.
  final List<String> unresolvedTasks;

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

    out.writeln('## Files changed in the working tree');
    out.writeln();
    out.writeln(_changesSection());
    out.writeln();

    out.writeln('## Conversation so far');
    out.writeln();
    out.writeln(_recapSection());
    out.writeln();

    if (unresolvedTasks.isNotEmpty) {
      out.writeln('## Still open, per the user');
      out.writeln();
      for (final task in unresolvedTasks) {
        out.writeln('- [ ] $task');
      }
      out.writeln();
    }

    out.writeln('## What you are being asked to do');
    out.writeln();
    out.writeln(instruction.trim());
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
            'remember doing.';

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
