import '../../sessions/domain/handoff_packet.dart';

/// The document a review session is handed as its first message.
///
/// ## Why this is not a handoff packet
///
/// `HandoffPacket` exists to make a second agent able to *continue* work, and
/// its whole discipline is aimed at that: quote the conversation, never rewrite
/// it as the reader's own, say how much was left out. A review needs the
/// opposite emphasis. The reviewer is not continuing anything, so the
/// conversation is not what it needs — it needs **the diff and the claim**, and
/// an explicit instruction not to touch either.
///
/// The two documents share one rule, for the same reason: **null renders as a
/// sentence admitting it**, never as an omitted section. A missing "what
/// changed" heading reads as "nothing changed", and a reviewer that believes
/// the tree is clean will pass a change it never looked at. That is the exact
/// failure a review exists to prevent, so it is the one the wording spends its
/// care on.
///
/// ## Why the verdict contract is spelled out
///
/// A review that concludes in prose is a review nobody can find later. The
/// brief names the tool calls that turn a reading into a record, and it says
/// that finding nothing is a *pass with a reason* rather than saying nothing at
/// all — an unrecorded clean review is indistinguishable from a review that
/// never happened.
///
/// ## Why findings become threads and not just notes
///
/// A verdict answers "is this change all right"; it does not answer "what do I
/// do on Tuesday". The findings underneath it used to live only in
/// `verification_note`s, which is to say in a transcript — anchored to nothing,
/// triageable by nobody, and impossible to reply to. So the brief separates the
/// two acts on purpose: a **note** is the reviewer's reasoning, including for
/// the parts that were fine, and a **thread** (`review_thread_add`) is a thing
/// somebody has to decide about, hung off the file and the lines it is about.
/// The reviewer files threads as `open`, never as "should fix": a reviewer that
/// could mark its own findings must-fix would be writing the author's task list
/// and having it read as the user's, which is the same objection
/// `decision_tools.dart` raises about an agent recording an approval.
class ReviewBrief {
  const ReviewBrief({
    required this.authorAgentName,
    required this.reviewerAgentName,
    required this.subjectTitle,
    required this.subjectSessionId,
    this.claim,
    this.workingDirectory,
    this.branch,
    this.baseBranch,
    this.commitsAhead,
    this.changes,
    this.diff,
    this.diffOmittedCharacters = 0,
    this.permissionSummary,
  });

  /// The agent that wrote the code.
  final String authorAgentName;

  /// The agent about to check it.
  final String reviewerAgentName;

  final String subjectTitle;

  /// **Karmashala's** id for the session under review, not the CLI's.
  ///
  /// This is the id the verdict is filed under: `verification_start`'s
  /// `sessionId` is compared against `sessions.id`, and a fan-out candidate
  /// names the same value. Handing over the agent's own external id — which is
  /// what a handoff packet quotes, because a human reads that one — would file
  /// the verdict against nothing and quietly produce an unattributed run.
  final String subjectSessionId;

  /// What the author says the change does, in their words or the user's.
  ///
  /// Null is "nobody wrote one down", and renders as that. A review with no
  /// claim is still worth doing — "does this diff look right" is a question —
  /// but the reviewer has to know it is judging without a stated intent rather
  /// than assuming there was none.
  final String? claim;

  final String? workingDirectory;
  final String? branch;
  final String? baseBranch;
  final int? commitsAhead;

  /// Changed files, or **null for "git could not be asked"**. An empty list is
  /// the positive answer "the working tree is clean".
  final List<HandoffChange>? changes;

  /// The unified diff, already trimmed to [ReviewDiffBudget]. Null when git
  /// would not produce one.
  final String? diff;

  /// How many characters of [diff] were dropped to fit the budget.
  final int diffOmittedCharacters;

  /// What the review session may and may not do, in the words the permission
  /// carry uses. Null when nothing was resolved.
  final String? permissionSummary;

  /// The brief as Markdown, which is what the reviewer receives as its first
  /// message.
  String render() {
    final out = StringBuffer()
      ..writeln('# Review this change')
      ..writeln()
      ..writeln(
        'You are **$reviewerAgentName**, and you did not write the code below '
        '— **$authorAgentName** did, in this same directory. You are being '
        'asked to check it and report, which is a different job from '
        'improving it. Read it as work you are inheriting for judgement, not '
        'as something you remember doing.',
      )
      ..writeln()
      ..writeln('## What you are checking')
      ..writeln()
      ..writeln(_claimSection())
      ..writeln()
      ..writeln('## Where')
      ..writeln()
      ..writeln('- **Session under review:** "$subjectTitle" '
          '(`$subjectSessionId`)')
      ..writeln('- **Author:** $authorAgentName');
    if (workingDirectory != null) {
      out.writeln('- **Working directory:** `$workingDirectory`');
    }
    out
      ..writeln('- **Branch:** ${_branchLine()}')
      ..writeln();

    out
      ..writeln('## Files changed in the working tree')
      ..writeln()
      ..writeln(_changesSection())
      ..writeln()
      ..writeln('## The diff')
      ..writeln()
      ..writeln(_diffSection())
      ..writeln()
      ..writeln('## What you may do')
      ..writeln()
      ..writeln(
        'Read anything, run anything you need to reach a verdict — the tests, '
        'the analyzer, the app. **Do not fix what you find.** No edits, no '
        'commits, no reverts, no pushes: a reviewer that repairs the change is '
        'no longer evidence that the change was right, and the author\'s '
        'session is still there to do the fixing.',
      );
    if (permissionSummary != null) {
      out
        ..writeln()
        ..writeln(permissionSummary!.trim());
    }
    out
      ..writeln()
      ..writeln('## How to record what you find')
      ..writeln()
      ..writeln(
        'Your verdict has to be a record, not a message in a conversation '
        'nobody opens. Four calls, and one of them is the only one anybody '
        'can answer:',
      )
      ..writeln()
      ..writeln(
        '1. `verification_start(change: true, sessionId: "$subjectSessionId", '
        'title: "…")` — `change: true` says the subject is a diff rather than '
        'a page, and `sessionId` files the verdict against the work rather '
        'than against you. Both matter: that pairing is what makes this count '
        'as an independent check instead of a self-graded pass.',
      )
      ..writeln(
        '2. `review_thread_add(path: "…", startLine: …, comment: "…")` for '
        'each thing you find in the code — **this is where a finding goes.** '
        'A finding described only in your notes is a paragraph in a transcript '
        'that the person who has to act on it will never open; a thread is '
        'anchored to the file, sits beside the line in the Changes panel, can '
        'be triaged, and can be replied to by whoever fixes it. Line numbers '
        'are counted in the file as it is on disk right now, and the thread '
        'records the file\'s content hash so that it says "detached" later '
        'rather than quietly pointing at whatever ends up on that line. Omit '
        'the range for a comment about the whole file. Quote the code in '
        '`excerpt`: that is what a human reads once the file has moved on.',
      )
      ..writeln(
        '3. `verification_note(text: "…")` as you go — what you looked at, '
        'what you expected, what you saw. This is your **reasoning**, and it '
        'is a different thing from a finding: nothing is collected for you on '
        'a change run, so these notes are the only record of how you reached '
        'the verdict, including for the parts where nothing was wrong.',
      )
      ..writeln(
        '4. `verification_finish(verdict: "pass" | "fail" | "inconclusive", '
        'reason: "…")`.',
      )
      ..writeln()
      ..writeln(
        'A thread you raise starts as **open** — a claim somebody still has to '
        'triage — and only a human moves it to "should fix", which is the set '
        'that gets sent back to the author. Do not skip the threads because '
        'you also wrote a note: the note is why you concluded something, and '
        'the thread is the thing that gets fixed.',
      )
      ..writeln()
      ..writeln(
        '**A review that finds nothing still finishes.** That is a `pass` with '
        'a reason saying what you checked and what held — silence is '
        'indistinguishable from a review that never happened, and it is the '
        'one outcome that helps nobody. Use `fail` for something you can point '
        'at, and `inconclusive` honestly when you could not check the thing '
        'that mattered; a review you could not complete is not a pass.',
      );
    return out.toString().trimRight();
  }

  String _claimSection() {
    final stated = claim?.trim();
    if (stated == null || stated.isEmpty) {
      return 'Not recorded — nobody wrote down what this change is supposed to '
          'do. Judge the diff on its own terms and say in your verdict that '
          'you were checking it without a stated intent.';
    }
    return 'The claim, in the words it was made in:\n\n'
        '${stated.split('\n').map((line) => '> $line').join('\n')}';
  }

  String _branchLine() {
    if (branch == null) return 'unknown (git could not be asked)';
    final ahead = commitsAhead;
    if (ahead == null || baseBranch == null) return '`$branch`';
    return '`$branch` — $ahead commit${ahead == 1 ? '' : 's'} ahead of '
        '`$baseBranch`';
  }

  String _changesSection() {
    final files = changes;
    if (files == null) {
      return 'Could not be read — git did not answer. Run `git status` '
          'yourself before assuming the tree is clean.';
    }
    if (files.isEmpty) {
      return 'None: the working tree is clean. Whatever was done is committed, '
          'so read the branch\'s commits rather than the working tree.';
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

  String _diffSection() {
    final text = diff;
    if (text == null) {
      return 'Could not be read — git did not answer. Run `git diff` yourself; '
          'do not review from the file list alone.';
    }
    if (text.trim().isEmpty) {
      return 'Empty: nothing is uncommitted. Read the commits on the branch '
          'with `git log -p ${baseBranch == null ? '' : '$baseBranch..'}'
          '${branch ?? 'HEAD'}`.';
    }
    final out = StringBuffer()
      ..writeln('```diff')
      ..writeln(text.trimRight())
      ..writeln('```');
    if (diffOmittedCharacters > 0) {
      out
        ..writeln()
        ..writeln(
          '_The first ${text.length} characters. $diffOmittedCharacters more '
          'were not included — run `git diff` to read the rest before you '
          'conclude anything about what is missing here._',
        );
    }
    return out.toString().trimRight();
  }
}

/// How much of a diff the brief carries inline.
///
/// The reviewer is standing in the directory and can run `git diff` itself, so
/// the inline copy is an opening move rather than the only source. What it buys
/// is a first turn spent reading instead of a first turn spent fetching — and
/// what it costs is input tokens on every review, which is why it is bounded.
class ReviewDiffBudget {
  const ReviewDiffBudget({this.maxCharacters = 12000});

  final int maxCharacters;
}

/// Trims [diff] to [budget], keeping the **head**, and reports what was dropped.
///
/// Head rather than tail, which is the opposite of [trimRecap]'s choice and for
/// the opposite reason: a conversation's state is at its end, but a diff's
/// files are in a stable order and the reviewer needs to start somewhere it can
/// then continue from with `git diff`. Truncating the middle would leave a
/// hunk header without its body, which reads as a change that is not there.
({String text, int omitted}) trimReviewDiff(
  String diff, [
  ReviewDiffBudget budget = const ReviewDiffBudget(),
]) {
  if (diff.length <= budget.maxCharacters) return (text: diff, omitted: 0);
  final kept = diff.substring(0, budget.maxCharacters);
  return (text: kept, omitted: diff.length - kept.length);
}
