import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala_git/github.dart';
import 'package:karmashala_session/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// **The rules, and the order that settles an argument between them.**
///
/// The priority order is the part of saved sections most likely to be argued
/// with later, so it is asserted here on its own — two sections and one row,
/// with no database, no widget tree and no provider graph in the way. If the
/// order is ever changed, this file is where the change has to be defended.
SectionFacts facts({
  String id = 's1',
  String title = 'Work',
  bool imported = false,
  SessionStatus? status = SessionStatus.running,
  String? branch,
  PullRequestState? pullRequestState,
  ChecksState? checks,
  bool awaitingInput = false,
}) => SectionFacts(
  id: id,
  title: title,
  imported: imported,
  status: status,
  branch: branch,
  pullRequestState: pullRequestState,
  checks: checks,
  awaitingInput: awaitingInput,
);

ExplorerSection section(
  String id,
  SectionRule rule, {
  required int position,
  Set<String> members = const {},
}) => ExplorerSection(
  id: id,
  name: id,
  rule: rule,
  position: position,
  members: members,
);

void main() {
  group('a rule reads only what has been measured', () {
    test('checks failing needs a failing verdict, not an absent one', () {
      const rule = ChecksFailingRule();
      expect(rule.matches(facts(checks: ChecksState.failing)), isTrue);
      expect(rule.matches(facts(checks: ChecksState.passing)), isFalse);
      expect(rule.matches(facts(checks: ChecksState.pending)), isFalse);
      // The whole point of the nullable fields: nobody has asked `gh` about
      // this checkout, which is not the same as "the build is green".
      expect(rule.matches(facts()), isFalse);
    });

    test('pull request open ignores merged and closed', () {
      const rule = PullRequestOpenRule();
      expect(
        rule.matches(facts(pullRequestState: PullRequestState.open)),
        isTrue,
      );
      expect(
        rule.matches(facts(pullRequestState: PullRequestState.merged)),
        isFalse,
      );
      expect(
        rule.matches(facts(pullRequestState: PullRequestState.closed)),
        isFalse,
      );
      expect(rule.matches(facts()), isFalse);
    });

    test('ended in failure is the row\'s own record, and not cancelled', () {
      const rule = EndedInFailureRule();
      expect(rule.matches(facts(status: SessionStatus.failed)), isTrue);
      // A session the user stopped is not a session that failed. Folding the
      // two would fill the group with work nobody wants back.
      expect(rule.matches(facts(status: SessionStatus.cancelled)), isFalse);
      expect(rule.matches(facts(status: SessionStatus.completed)), isFalse);
      // An imported conversation has no lifecycle of its own.
      expect(rule.matches(facts(imported: true, status: null)), isFalse);
    });

    test('awaiting input is the ambient waiting flag', () {
      const rule = AwaitingInputRule();
      expect(rule.matches(facts(awaitingInput: true)), isTrue);
      expect(rule.matches(facts()), isFalse);
    });

    test('the explicit rules match nothing by predicate', () {
      // Their membership is a list, not a question — and answering `false`
      // here is what lets [claimantFor] resolve explicit claims in their own
      // pass without a special case.
      for (final rule in const [PinnedRule(), ManualRule()]) {
        expect(
          rule.matches(
            facts(
              status: SessionStatus.failed,
              checks: ChecksState.failing,
              awaitingInput: true,
            ),
          ),
          isFalse,
        );
        expect(rule.isManual, isTrue);
      }
    });
  });

  group('a branch glob', () {
    test('* stays inside one path segment', () {
      final rule = BranchGlobRule('release/*');
      expect(rule.matches(facts(branch: 'release/1.4')), isTrue);
      expect(rule.matches(facts(branch: 'release/hotfix')), isTrue);
      // The reason `*` does not cross slashes: `release/*` means "the release
      // branches", and a repository that numbers them `release/2026/q1` would
      // otherwise make the obvious pattern quietly right for the wrong reason.
      expect(rule.matches(facts(branch: 'release/2026/q1')), isFalse);
      expect(rule.matches(facts(branch: 'releases/1.4')), isFalse);
      expect(rule.matches(facts(branch: 'feat/release/1.4')), isFalse);
    });

    test('** crosses them, and ? is exactly one character', () {
      expect(
        BranchGlobRule('release/**').matches(facts(branch: 'release/2026/q1')),
        isTrue,
      );
      expect(
        BranchGlobRule('hotfix-?').matches(facts(branch: 'hotfix-9')),
        isTrue,
      );
      expect(
        BranchGlobRule('hotfix-?').matches(facts(branch: 'hotfix-42')),
        isFalse,
      );
    });

    test(
      'it is anchored at both ends and takes regex characters literally',
      () {
        expect(BranchGlobRule('main').matches(facts(branch: 'main')), isTrue);
        expect(
          BranchGlobRule('main').matches(facts(branch: 'maintain')),
          isFalse,
        );
        // A `.` in a branch name is a dot, not "any character".
        expect(
          BranchGlobRule('v1.0').matches(facts(branch: 'v1x0')),
          isFalse,
          reason: 'a glob is not a regular expression wearing a hat',
        );
        expect(
          BranchGlobRule('*fix*').matches(facts(branch: 'a-fix-b')),
          isTrue,
        );
      },
    );

    test('an unmeasured branch matches nothing, not even `*`', () {
      // The failure this guards is specific and silent: `*` compiles to
      // `^[^/]*$`, which matches the empty string — so a branch defaulted to
      // `''` instead of left null would file every unopened session in the
      // workspace into the first glob section a user wrote.
      expect(BranchGlobRule('*').matches(facts()), isFalse);
      expect(BranchGlobRule('release/*').matches(facts()), isFalse);
    });

    test('the pattern survives a round-trip through storage', () {
      final rule = SectionRule.fromStorage('branchGlob', 'release/*');
      expect(rule, isA<BranchGlobRule>());
      expect(rule!.pattern, 'release/*');
      expect(rule.matches(facts(branch: 'release/9')), isTrue);
      // A glob rule with no pattern is not a rule; the DAO drops the row
      // rather than inventing `*`, which would match everything.
      expect(SectionRule.fromStorage('branchGlob', null), isNull);
      expect(SectionRule.fromStorage('somethingNewer', null), isNull);
    });
  });

  group('when several sections want the same session', () {
    test('explicit membership beats every rule, however far down it sits', () {
      final sections = [
        section('pinned', const PinnedRule(), position: 0),
        section('red', const ChecksFailingRule(), position: 1),
        section('mine', const ManualRule(), position: 2, members: const {'s1'}),
      ];
      final red = facts(checks: ChecksState.failing);

      // The manual group is *below* the rule that also matches, and still
      // wins: putting a row somewhere by hand is a statement about that row.
      expect(claimantFor(sections, red)?.id, 'mine');
      // And the pin beats the manual group, because Pinned is above it.
      expect(claimantFor(sections, red, pinnedIds: {'s1'})?.id, 'pinned');
    });

    test('among rules, the order the user sees is the order that decides', () {
      final red = facts(
        checks: ChecksState.failing,
        pullRequestState: PullRequestState.open,
        branch: 'release/1.4',
      );
      final severityFirst = [
        section('red', const ChecksFailingRule(), position: 0),
        section('release', BranchGlobRule('release/*'), position: 1),
      ];
      expect(claimantFor(severityFirst, red)?.id, 'red');

      // The same two sections, dragged into the other order, file the same row
      // in the other group. That is the whole feature of position-as-priority:
      // "I care about my release branches more than about red builds in
      // general" is a sentence the sidebar can express.
      final releaseFirst = [
        section('release', BranchGlobRule('release/*'), position: 0),
        section('red', const ChecksFailingRule(), position: 1),
      ];
      expect(claimantFor(releaseFirst, red)?.id, 'release');
    });

    test('a session no section wants is claimed by none', () {
      final sections = [
        section('red', const ChecksFailingRule(), position: 0),
        section('mine', const ManualRule(), position: 1),
      ];
      expect(claimantFor(sections, facts()), isNull);
    });
  });

  group('assignSections', () {
    test('gives every section a list and files each row exactly once', () {
      final sections = [
        section('pinned', const PinnedRule(), position: 0),
        section('red', const ChecksFailingRule(), position: 1),
        section('waiting', const AwaitingInputRule(), position: 2),
        section('dead', const EndedInFailureRule(), position: 3),
      ];
      final rows = [
        facts(id: 'a', checks: ChecksState.failing, awaitingInput: true),
        facts(id: 'b', awaitingInput: true, status: SessionStatus.failed),
        facts(id: 'c', status: SessionStatus.failed),
        facts(id: 'd'),
        facts(id: 'e', checks: ChecksState.failing),
      ];

      final assignment = assignSections(sections, rows, pinnedIds: {'e'});
      expect(assignment.keys, ['pinned', 'red', 'waiting', 'dead']);
      expect([for (final f in assignment['pinned']!) f.id], ['e']);
      expect([for (final f in assignment['red']!) f.id], ['a']);
      expect([for (final f in assignment['waiting']!) f.id], ['b']);
      expect([for (final f in assignment['dead']!) f.id], ['c']);

      // Every row lands in at most one list, and `d` — which nothing matches —
      // lands in none. A section list is a partition, not a set of overlapping
      // filters, so a workspace's rows cannot be counted twice.
      final filed = [
        for (final list in assignment.values)
          for (final f in list) f.id,
      ];
      expect(filed.toSet().length, filed.length);
      expect(filed, isNot(contains('d')));
    });

    test('no sections is an empty answer rather than a crash', () {
      expect(assignSections(const [], [facts()]), isEmpty);
    });
  });
}
