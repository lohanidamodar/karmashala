import 'package:flutter/foundation.dart';

import 'pull_request_snapshot.dart';

/// How a branch-protection reading went, because "no rules" and "not allowed
/// to look" are different answers and only one of them is about the branch.
enum BranchProtectionRead {
  /// GitHub answered with the branch's rules.
  read,

  /// GitHub answered **403**. `/branches/{b}/protection` is admin-only on a
  /// great many repositories, so this is the ordinary outcome for anyone who
  /// is not an owner — a fact about the token, not about the branch, and the
  /// message says so rather than guessing a rule.
  forbidden,

  /// Nothing usable: `gh` missing or logged out, a 404 because classic branch
  /// protection is not what is guarding this branch (a ruleset can block a
  /// merge and answer "Branch not protected" here), or a body that did not
  /// parse. Never read as "there are no rules".
  unknown,
}

/// What `gh api repos/{owner}/{repo}/branches/{b}/protection` says a branch
/// requires.
///
/// **This exists because `mergeStateStatus: BLOCKED` names nothing.** It is
/// one value covering every branch-protection rule GitHub has, and every open
/// pull request in a protected repository reports it — so the strip could only
/// ever say "GitHub is blocking this merge; open the pull request to see why".
/// The rule is a second call away, and this is that call's answer.
///
/// **Every field degrades to "did not say", never to a zero or a false.** A
/// body that arrives without `required_pull_request_reviews` means the reading
/// did not carry it; reading that as "no review is required" would let the
/// strip announce a rule that is not the one holding the merge.
@immutable
class BranchProtection {
  const BranchProtection({
    required this.status,
    this.branch,
    this.requiredApprovals,
    this.requiresCodeOwnerReview = false,
    this.requiredChecks = const [],
    this.requiresConversationResolution = false,
    this.requiresSignatures = false,
    this.requiresLinearHistory = false,
  });

  /// Nothing asked, or nothing usable came back.
  static const unknown = BranchProtection(status: BranchProtectionRead.unknown);

  /// The rules are there and this token may not read them.
  static const forbidden = BranchProtection(
    status: BranchProtectionRead.forbidden,
  );

  final BranchProtectionRead status;

  /// The branch the rules were read for — the *base*, which is what protection
  /// applies to, not the branch the session is on.
  final String? branch;

  /// `required_approving_review_count`. Null is "did not say".
  final int? requiredApprovals;

  final bool requiresCodeOwnerReview;

  /// The named contexts under `required_status_checks`.
  final List<String> requiredChecks;

  final bool requiresConversationResolution;
  final bool requiresSignatures;
  final bool requiresLinearHistory;

  /// Every rule this branch carries, in words, for a sentence that lists them.
  List<String> get rules => [
    if ((requiredApprovals ?? 0) > 0)
      '$requiredApprovals approving '
          'review${requiredApprovals == 1 ? '' : 's'}',
    if (requiresCodeOwnerReview) 'a review from a code owner',
    if (requiredChecks.isNotEmpty)
      'the ${requiredChecks.length == 1 ? 'check' : 'checks'} '
          '${requiredChecks.map((c) => '`$c`').join(', ')}',
    if (requiresConversationResolution) 'every review conversation resolved',
    if (requiresSignatures) 'signed commits',
    if (requiresLinearHistory) 'a linear history',
  ];

  /// What to say about a `BLOCKED` merge, or null when this reading adds
  /// nothing and the caller should keep its own sentence.
  ///
  /// **Only a rule we can show is unmet gets named as the reason.** The
  /// endpoint says which rules *exist*; whether each one is satisfied is a
  /// separate question, and for two of them the pull request already answers
  /// it — a review decision that is not `APPROVED` against a required approval
  /// count, and a check rollup that has not finished against required
  /// contexts. Those two are named outright. For the rest the honest sentence
  /// lists what the branch requires and leaves the choosing to the page,
  /// which is still strictly more than `BLOCKED` said.
  String? describeFor(PullRequestSnapshot pr) {
    final on = branch == null ? 'this branch' : '`$branch`';
    switch (status) {
      case BranchProtectionRead.unknown:
        return null;
      case BranchProtectionRead.forbidden:
        return 'GitHub is blocking this merge under a branch-protection rule, '
            'and reading which one needs admin rights on this repository '
            '(`gh` answered 403). Open the pull request to see why.';
      case BranchProtectionRead.read:
        break;
    }

    final approvals = requiredApprovals ?? 0;
    final decision = pr.reviewDecision;
    final unapproved =
        decision == ReviewDecision.reviewRequired ||
        decision == ReviewDecision.none;
    if (approvals > 0 && unapproved) {
      return 'Branch protection on $on requires $approvals approving '
          'review${approvals == 1 ? '' : 's'}; this one has none yet.';
    }
    if (requiresCodeOwnerReview && unapproved) {
      return 'Branch protection on $on requires a review from a code owner.';
    }
    if (requiredChecks.isNotEmpty) {
      final named = requiredChecks.map((c) => '`$c`').join(', ');
      if (pr.checks.state == ChecksState.none) {
        return 'Branch protection on $on requires $named, and nothing has '
            'reported on this branch.';
      }
      if (pr.checks.state == ChecksState.pending) {
        return 'Branch protection on $on requires $named, and the checks have '
            'not finished.';
      }
    }

    final all = rules;
    if (all.isEmpty) return null;
    return 'Branch protection on $on is blocking this merge; it requires '
        '${_list(all)}.';
  }

  @override
  bool operator ==(Object other) =>
      other is BranchProtection &&
      other.status == status &&
      other.branch == branch &&
      other.requiredApprovals == requiredApprovals &&
      other.requiresCodeOwnerReview == requiresCodeOwnerReview &&
      listEquals(other.requiredChecks, requiredChecks) &&
      other.requiresConversationResolution == requiresConversationResolution &&
      other.requiresSignatures == requiresSignatures &&
      other.requiresLinearHistory == requiresLinearHistory;

  @override
  int get hashCode => Object.hash(
    status,
    branch,
    requiredApprovals,
    requiresCodeOwnerReview,
    Object.hashAll(requiredChecks),
    requiresConversationResolution,
    requiresSignatures,
    requiresLinearHistory,
  );

  @override
  String toString() => 'BranchProtection(${status.name}, $branch, $rules)';
}

String _list(List<String> parts) {
  if (parts.length == 1) return parts.single;
  return '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}
