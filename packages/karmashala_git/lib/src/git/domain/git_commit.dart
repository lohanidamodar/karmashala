/// A commit summary from `git log`.
class GitCommit {
  const GitCommit({
    required this.sha,
    required this.author,
    required this.subject,
  });

  final String sha;
  final String author;
  final String subject;

  String get shortSha => sha.length >= 7 ? sha.substring(0, 7) : sha;

  @override
  bool operator ==(Object other) =>
      other is GitCommit &&
      other.sha == sha &&
      other.author == author &&
      other.subject == subject;

  @override
  int get hashCode => Object.hash(sha, author, subject);

  @override
  String toString() => 'GitCommit($shortSha, $subject)';
}
