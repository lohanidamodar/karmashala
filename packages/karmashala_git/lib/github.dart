/// GitHub's own vocabulary: repositories, issues, pull requests, the snapshot
/// a review strip is drawn from, the merge strategies a repository allows and
/// the branch-protection rule behind a blocked merge.
///
/// `GitHubService` is the `gh` client that fills them: every call goes through
/// a `CommandRunner`, so one code path works locally, in WSL and over SSH, and
/// the parsers it feeds are pure functions over `gh --json` output.
library;

export 'src/github/data/github_service.dart';
export 'src/github/domain/branch_protection.dart';
export 'src/github/domain/github_repo.dart';
export 'src/github/domain/issue.dart';
export 'src/github/domain/merge_strategies.dart';
export 'src/github/domain/pull_request.dart';
export 'src/github/domain/pull_request_snapshot.dart';
