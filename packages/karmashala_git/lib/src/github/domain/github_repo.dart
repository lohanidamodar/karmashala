/// GitHub repository metadata, as returned by `gh repo view --json`.
class GitHubRepo {
  const GitHubRepo({
    required this.nameWithOwner,
    required this.url,
    required this.isPrivate,
    required this.stargazerCount,
    this.description,
    this.defaultBranch,
  });

  final String nameWithOwner;
  final String url;
  final bool isPrivate;
  final int stargazerCount;
  final String? description;
  final String? defaultBranch;

  @override
  bool operator ==(Object other) =>
      other is GitHubRepo &&
      other.nameWithOwner == nameWithOwner &&
      other.url == url &&
      other.isPrivate == isPrivate &&
      other.stargazerCount == stargazerCount &&
      other.description == description &&
      other.defaultBranch == defaultBranch;

  @override
  int get hashCode => Object.hash(
    nameWithOwner,
    url,
    isPrivate,
    stargazerCount,
    description,
    defaultBranch,
  );

  @override
  String toString() => 'GitHubRepo($nameWithOwner)';
}
