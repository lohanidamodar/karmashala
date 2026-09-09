import 'package:karmashala_git/github.dart';
import '../../sessions/domain/delivery_stage.dart';
import '../../sessions/domain/session_status.dart';

/// **What a rule may ask about one session, and nothing else.**
///
/// Every field here is a fact the app has *already* read for another reason:
/// the session row's own status, the delivery reading a card or a strip paid
/// for, the pull request a strip fetched, and the ambient waiting list the
/// status watcher publishes. Nothing in this type can be produced by asking
/// git, `gh` or SQLite a new question, and that is the whole design constraint
/// — `test/features/scale/quiet_soak_cost_test.dart` pins **zero** statements
/// over an hour of idle at a hundred panes, and a section that reached for a
/// fact would have to reach for it once per session per rebuild.
///
/// Null is "we have not measured it", never "no" — the same rule
/// [SessionDelivery] sets, and it matters more here than there: a rule that
/// read an unmeasured branch as an empty string would quietly file every
/// unopened session under `release/*` the moment somebody wrote the glob `*`.
class SectionFacts {
  const SectionFacts({
    required this.id,
    required this.title,
    required this.imported,
    this.status,
    this.archived = false,
    this.branch,
    this.stage,
    this.pullRequestState,
    this.checks,
    this.awaitingInput = false,
  });

  /// The workspace row id — what selection, pinning and the DAO all key on.
  final String id;

  final String title;

  /// Whether this is an imported CLI conversation rather than a native session.
  ///
  /// Imported rows have no lifecycle of their own ([status] is null) and no
  /// checkout of their own, so they can only ever be matched by their
  /// repository's branch or by explicit membership. Said out loud because the
  /// alternative — silently dropping them — would make "everything on
  /// `release/*`" a lie on a workspace that is mostly imported history.
  final bool imported;

  /// The session row's own lifecycle. Null for [imported] rows.
  final SessionStatus? status;

  /// Whether the worktree has been archived away.
  final bool archived;

  /// The branch checked out where this session works, when something has
  /// measured it.
  final String? branch;

  /// How far the work has travelled, when a delivery reading exists.
  final DeliveryStage? stage;

  final PullRequestState? pullRequestState;

  /// The verdict on the pull request's checks. Null both when there is no pull
  /// request and when nobody has asked `gh` about this checkout yet — the two
  /// are told apart by [pullRequestState].
  final ChecksState? checks;

  /// Whether the agent is stopped at a prompt waiting on the user, per the
  /// ambient waiting list the status watcher keeps.
  ///
  /// Read from that list rather than from the attention *inbox* deliberately:
  /// the inbox retires an item the moment its session is looked at, which is
  /// right for a notification and wrong for a section — a group you can empty
  /// by glancing at it is a group you cannot work through.
  final bool awaitingInput;

  @override
  String toString() =>
      'SectionFacts($id, ${status?.name ?? 'imported'}, ${branch ?? '?'}, '
      'checks ${checks?.name ?? '-'}, awaiting $awaitingInput)';
}

/// The persisted discriminator for a [SectionRule].
///
/// A string in the database rather than an index, for the reason every enum in
/// this schema is stored by name: a reordered `values` list must not silently
/// re-file every section a user has made.
enum SectionRuleKind {
  /// Membership is the user's pin set. See [PinnedRule].
  pinned,

  /// Membership is whatever the user dropped in. See [ManualRule].
  manual,

  checksFailing,
  pullRequestOpen,
  awaitingInput,
  endedInFailure,
  branchGlob;

  static SectionRuleKind? byName(String? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// What decides whether a session belongs to a section.
///
/// Sealed, so adding a rule is a compile error everywhere the set is switched
/// over — including the DAO, which is the one place a forgotten case would show
/// up as data loss rather than as a missing group.
sealed class SectionRule {
  const SectionRule();

  SectionRuleKind get kind;

  /// The rule's one parameter, for the rules that take one. Persisted as a
  /// single nullable column rather than as a JSON blob: there is exactly one
  /// parameterised rule today, and a blob would hide the day there are two.
  String? get pattern => null;

  /// Whether [facts] satisfies this rule.
  ///
  /// **Explicit rules answer `false`.** [PinnedRule] and [ManualRule] have no
  /// predicate at all — their membership is a list, not a question — and
  /// answering `false` here keeps the one caller ([assignSections]) honest:
  /// explicit membership is resolved in its own pass, before any rule runs.
  bool matches(SectionFacts facts);

  /// Whether membership comes from a list the user maintains rather than from
  /// [matches].
  bool get isManual =>
      kind == SectionRuleKind.pinned || kind == SectionRuleKind.manual;

  static SectionRule? fromStorage(String? kind, String? pattern) =>
      switch (SectionRuleKind.byName(kind)) {
        SectionRuleKind.pinned => const PinnedRule(),
        SectionRuleKind.manual => const ManualRule(),
        SectionRuleKind.checksFailing => const ChecksFailingRule(),
        SectionRuleKind.pullRequestOpen => const PullRequestOpenRule(),
        SectionRuleKind.awaitingInput => const AwaitingInputRule(),
        SectionRuleKind.endedInFailure => const EndedInFailureRule(),
        SectionRuleKind.branchGlob =>
          pattern == null ? null : BranchGlobRule(pattern),
        null => null,
      };

  @override
  bool operator ==(Object other) =>
      other is SectionRule && other.kind == kind && other.pattern == pattern;

  @override
  int get hashCode => Object.hash(kind, pattern);
}

/// The one section that cannot be deleted, renamed, reordered or given a rule.
///
/// Its membership is [Settings.pinnedSessionIds] — the set the pin toggle in
/// every row menu already writes — rather than a members table of its own.
/// Two pin stores would be two answers to "is this pinned", and the row's own
/// pin glyph reads the settings one; a section that disagreed with the glyph
/// beside it would be worse than no section.
class PinnedRule extends SectionRule {
  const PinnedRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.pinned;

  @override
  bool matches(SectionFacts facts) => false;
}

/// A group the user fills by hand.
class ManualRule extends SectionRule {
  const ManualRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.manual;

  @override
  bool matches(SectionFacts facts) => false;
}

/// A pull request whose checks have gone red.
///
/// Reads [SectionFacts.checks] rather than [DeliveryStage.checksFailing] so the
/// answer is the same on a row whose stage was never computed. The two agree by
/// construction — `SessionDelivery.stage` derives `checksFailing` from exactly
/// this field — and reading the narrower one means a session with a red build
/// and an uncommitted edit still lands here.
class ChecksFailingRule extends SectionRule {
  const ChecksFailingRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.checksFailing;

  @override
  bool matches(SectionFacts facts) => facts.checks == ChecksState.failing;
}

/// A pull request that is open, whatever its checks say.
class PullRequestOpenRule extends SectionRule {
  const PullRequestOpenRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.pullRequestOpen;

  @override
  bool matches(SectionFacts facts) =>
      facts.pullRequestState == PullRequestState.open;
}

/// An agent stopped at a prompt, waiting on the user.
class AwaitingInputRule extends SectionRule {
  const AwaitingInputRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.awaitingInput;

  @override
  bool matches(SectionFacts facts) => facts.awaitingInput;
}

/// A session whose own row records that it ended badly.
///
/// The durable fact, not the live one: `SessionStatus.failed` is what the row
/// goes on saying after the process is gone, which is the difference between a
/// section you can come back to in the morning and one that empties itself
/// overnight. `cancelled` is deliberately **not** here — a session the user
/// stopped is not a session that failed, and folding the two would fill this
/// group with work nobody wants back.
class EndedInFailureRule extends SectionRule {
  const EndedInFailureRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.endedInFailure;

  @override
  bool matches(SectionFacts facts) => facts.status == SessionStatus.failed;
}

/// A branch matching a glob — `release/*`, `feat/**`, `hotfix-?`.
///
/// The pattern is compiled once, when the rule is constructed, because a
/// section is matched against every session in the workspace on every session
/// change and `RegExp` compilation is the one part of matching that is not
/// free.
class BranchGlobRule extends SectionRule {
  BranchGlobRule(this.glob) : _pattern = compileBranchGlob(glob);

  final String glob;
  final RegExp _pattern;

  @override
  SectionRuleKind get kind => SectionRuleKind.branchGlob;

  @override
  String? get pattern => glob;

  @override
  bool matches(SectionFacts facts) {
    final branch = facts.branch;
    // Null is "nobody has measured this checkout", and an unmeasured branch
    // must not match anything — see [SectionFacts].
    return branch != null && _pattern.hasMatch(branch);
  }
}

/// Compiles a branch glob to the regular expression that matches it.
///
/// The three wildcards, and why they are these three:
///
/// * `*` — any run of characters **except `/`**. `release/*` is the example in
///   every request for this feature, and it means "the release branches", not
///   "release/ and everything nested under it". A `*` that crossed slashes
///   would make the obvious pattern quietly wrong on a repository that uses
///   `release/2026/q1`.
/// * `**` — any run, slashes included, for when crossing them is the point.
/// * `?` — exactly one non-`/` character.
///
/// Anchored at both ends: a glob describes a whole branch name. A user who
/// wants "contains" writes `*fix*`, which reads as what it does.
///
/// Case-sensitive, because git refs are.
RegExp compileBranchGlob(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buffer.write('.*');
        i++;
      } else {
        buffer.write('[^/]*');
      }
    } else if (char == '?') {
      buffer.write('[^/]');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

/// The id the v29 migration seeds the built-in Pinned section under.
///
/// A literal rather than a generated id, and it has to be: the section is
/// created by a migration, which has no id generator, and the UI needs to be
/// able to name it without a lookup.
const String kPinnedSectionId = 'section-pinned';

/// One saved group in the Explorer sidebar.
class ExplorerSection {
  const ExplorerSection({
    required this.id,
    required this.name,
    required this.rule,
    required this.position,
    this.collapsed = true,
    this.members = const {},
  });

  final String id;
  final String name;
  final SectionRule rule;

  /// Where the section sits in the sidebar, ascending. **Also its priority** —
  /// see [assignSections].
  final int position;

  /// Whether the section is folded shut.
  ///
  /// Defaults to shut, and every seeded section is written shut, because a
  /// collapsed section costs nothing at all: nothing about it is matched and no
  /// row under it is built. See [explorerSectionAssignmentProvider].
  final bool collapsed;

  /// The rows the user put here by hand. Empty for every rule section, and for
  /// [PinnedRule], whose membership is the settings pin set.
  final Set<String> members;

  /// Whether this section is the built-in Pinned group.
  bool get isPinned => rule.kind == SectionRuleKind.pinned;

  /// Whether the user may delete, rename, reorder or re-rule it.
  bool get isEditable => !isPinned;

  ExplorerSection copyWith({
    String? name,
    SectionRule? rule,
    int? position,
    bool? collapsed,
    Set<String>? members,
  }) => ExplorerSection(
    id: id,
    name: name ?? this.name,
    rule: rule ?? this.rule,
    position: position ?? this.position,
    collapsed: collapsed ?? this.collapsed,
    members: members ?? this.members,
  );

  @override
  bool operator ==(Object other) =>
      other is ExplorerSection &&
      other.id == id &&
      other.name == name &&
      other.rule == rule &&
      other.position == position &&
      other.collapsed == collapsed &&
      _sameMembers(other.members, members);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    rule,
    position,
    collapsed,
    Object.hashAllUnordered(members),
  );

  static bool _sameMembers(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  String toString() =>
      'ExplorerSection($id "$name" ${rule.kind.name} @$position'
      '${collapsed ? ' collapsed' : ''})';
}

/// Which section claims each session, when several would take it.
///
/// **The order the user sees is the order that decides**, with one clause above
/// it:
///
/// 1. **Explicit beats derived.** A session the user pinned is in Pinned, and a
///    session the user dropped into a manual group is in that group, whatever
///    any rule says about it. Putting a row somewhere by hand is a statement
///    about *that row*; a rule is a statement about a shape. The moment a rule
///    could overrule a hand-placed row, "drag it here" stops meaning anything.
///    Between two explicit claims the topmost section wins, and Pinned is fixed
///    at position 0, so a pinned session is always in Pinned.
/// 2. **Among rules, position decides.** The first section, top to bottom,
///    whose rule matches takes the row.
///
/// The alternative — a fixed severity table, red-build outranks awaiting-input
/// outranks failed — was written and thrown away. It answers the common case
/// well and cannot be argued with, which is the problem: a user who wants their
/// `release/*` group to win over "Checks failing" has no way to say so, and
/// nobody reading the sidebar can tell why a red release branch is filed where
/// it is. Position is visible, it is already the thing the user arranges, and
/// dragging a section upwards is a sentence anyone can read. The seeded order
/// still *starts* at that severity ordering, so the default behaviour is the
/// one the table would have given.
///
/// A session that no section claims is in no section, and is drawn where it
/// always was — under its project.
///
/// [sections] must be in sidebar order. [pinnedIds] is the settings pin set,
/// which is [PinnedRule]'s membership.
Map<String, List<SectionFacts>> assignSections(
  List<ExplorerSection> sections,
  Iterable<SectionFacts> items, {
  Set<String> pinnedIds = const {},
}) {
  final claimed = <String, List<SectionFacts>>{
    for (final section in sections) section.id: <SectionFacts>[],
  };
  if (sections.isEmpty) return claimed;

  for (final item in items) {
    final section = claimantFor(sections, item, pinnedIds: pinnedIds);
    if (section != null) claimed[section.id]!.add(item);
  }
  return claimed;
}

/// The one section that takes [item], or null when none does.
///
/// Split out of [assignSections] so the rule can be asserted on its own — the
/// priority order is the part of this feature most likely to be argued with,
/// and an argument wants a function it can call with two sections and one row.
ExplorerSection? claimantFor(
  List<ExplorerSection> sections,
  SectionFacts item, {
  Set<String> pinnedIds = const {},
}) {
  // Clause 1: explicit membership, top to bottom.
  for (final section in sections) {
    final claims = switch (section.rule.kind) {
      SectionRuleKind.pinned => pinnedIds.contains(item.id),
      SectionRuleKind.manual => section.members.contains(item.id),
      _ => false,
    };
    if (claims) return section;
  }
  // Clause 2: rules, top to bottom.
  for (final section in sections) {
    if (section.rule.matches(item)) return section;
  }
  return null;
}
