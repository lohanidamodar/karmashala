/// GitHub's own vocabulary: repositories, issues, pull requests, the snapshot
/// a review strip is drawn from, the merge strategies a repository allows and
/// the branch-protection rule behind a blocked merge.
///
/// Values only; the `gh`-driven service that fills them lives with the app.
library;

export 'src/github/domain/branch_protection.dart';
export 'src/github/domain/github_repo.dart';
export 'src/github/domain/issue.dart';
export 'src/github/domain/merge_strategies.dart';
export 'src/github/domain/pull_request.dart';
export 'src/github/domain/pull_request_snapshot.dart';
