/// GitHub's own vocabulary: repositories, issues, pull requests, the snapshot
/// a review strip is drawn from, the merge strategies a repository allows and
/// the branch-protection rule behind a blocked merge.
///
/// `GitHubService` fills them over GitHub's API (`GithubClient`), as the token
/// `GithubCredentials` picks for the repository's host: one saved in Settings,
/// then the server's environment, then gh's login.
library;

export 'src/github/api/github_client.dart';
export 'src/github/api/github_credentials.dart';
export 'src/github/api/github_hosts.dart';
export 'src/github/data/github_service.dart';
export 'src/github/domain/branch_protection.dart';
export 'src/github/domain/github_repo.dart';
export 'src/github/domain/issue.dart';
export 'src/github/domain/merge_strategies.dart';
export 'src/github/domain/pull_request.dart';
export 'src/github/domain/pull_request_snapshot.dart';
export 'src/github/domain/workflow_run.dart';
