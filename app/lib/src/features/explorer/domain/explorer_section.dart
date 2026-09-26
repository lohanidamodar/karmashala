import 'package:karmashala_git/github.dart';
import 'package:karmashala_projects/karmashala_projects.dart'
    show StoredSection;
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/session.dart';

/// What a rule may ask about one session — only facts the app has already
/// read for another reason, so nothing here costs a git, `gh` or SQLite call.
/// Null always means "not measured yet", never "no".
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

  /// Whether this is an imported CLI conversation. Imported rows have no
  /// lifecycle and no checkout, so only a branch or explicit membership matches.
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
  /// request and when nobody has asked `gh` yet — [pullRequestState] separates.
  final ChecksState? checks;

  /// Whether the agent is stopped at a prompt. Read from the ambient waiting
  /// list, not the attention inbox, which retires an item once it is looked at.
  final bool awaitingInput;

  @override
  String toString() =>
      'SectionFacts($id, ${status?.name ?? 'imported'}, ${branch ?? '?'}, '
      'checks ${checks?.name ?? '-'}, awaiting $awaitingInput)';
}

/// The persisted discriminator for a [SectionRule]. Stored by name, not index:
/// a reordered `values` list must not re-file every section a user made.
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

/// What decides whether a session belongs to a section. Sealed, so adding a
/// rule is a compile error in the DAO, where a missed case would be data loss.
sealed class SectionRule {
  const SectionRule();

  SectionRuleKind get kind;

  /// The rule's one parameter, for the rules that take one. A column rather
  /// than a JSON blob, so the day there are two rules is not hidden.
  String? get pattern => null;

  /// Whether [facts] satisfies this rule. [PinnedRule] and [ManualRule] answer
  /// `false`: explicit membership is resolved in its own pass, before any rule.
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
/// Its membership is [Settings.pinnedSessionIds], so it cannot disagree with
/// the pin glyph on the row.
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

/// A pull request whose checks have gone red. Reads [SectionFacts.checks]
/// rather than the stage, so a red build with an uncommitted edit still lands.
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

/// A session whose own row records that it ended badly — the durable
/// `SessionStatus.failed`. `cancelled` is deliberately not here: a session the
/// user stopped is not one that failed.
class EndedInFailureRule extends SectionRule {
  const EndedInFailureRule();

  @override
  SectionRuleKind get kind => SectionRuleKind.endedInFailure;

  @override
  bool matches(SectionFacts facts) => facts.status == SessionStatus.failed;
}

/// A branch matching a glob — `release/*`, `feat/**`, `hotfix-?`. Compiled
/// once at construction: matching runs over every session on every change.
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

/// Compiles a branch glob to a regular expression. `*` does not cross `/` (so
/// `release/*` is not `release/2026/q1`), `**` does, `?` is one non-`/` char;
/// anchored at both ends and case-sensitive, because git refs are.
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

/// The id the v29 migration seeds the built-in Pinned section under. A literal
/// because a migration has no id generator and the UI must name it unaided.
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

  /// Whether the section is folded shut. Shut by default: a collapsed section
  /// is matched against nothing and builds no rows.
  final bool collapsed;

  /// The rows the user put here by hand. Empty for every rule section, and for
  /// [PinnedRule], whose membership is the settings pin set.
  final Set<String> members;

  /// [stored] as a section this build can draw, or null for a rule it does not
  /// know — a downgrade, and guessing would strip the rule on the next write.
  static ExplorerSection? fromStored(StoredSection stored) {
    final rule = SectionRule.fromStorage(stored.kind, stored.pattern);
    if (rule == null) return null;
    return ExplorerSection(
      id: stored.id,
      name: stored.name,
      rule: rule,
      position: stored.position,
      collapsed: stored.collapsed,
      members: stored.members,
    );
  }

  StoredSection toStored() => StoredSection(
    id: id,
    name: name,
    kind: rule.kind.name,
    pattern: rule.pattern,
    position: position,
    collapsed: collapsed,
    members: members,
  );

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

/// Which section claims each session when several would take it: explicit
/// membership wins over any rule, and among rules the topmost section in
/// sidebar order takes the row. A row nobody claims stays under its project.
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

/// The one section that takes [item], or null when none does. Split out so the
/// priority order can be asserted with two sections and one row.
ExplorerSection? claimantFor(
  List<ExplorerSection> sections,
  SectionFacts item, {
  Set<String> pinnedIds = const {},
}) {
  // Explicit membership, top to bottom.
  for (final section in sections) {
    final claims = switch (section.rule.kind) {
      SectionRuleKind.pinned => pinnedIds.contains(item.id),
      SectionRuleKind.manual => section.members.contains(item.id),
      _ => false,
    };
    if (claims) return section;
  }
  // Then rules, top to bottom.
  for (final section in sections) {
    if (section.rule.matches(item)) return section;
  }
  return null;
}
