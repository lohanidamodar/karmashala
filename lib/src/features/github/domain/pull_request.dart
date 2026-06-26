/// A GitHub pull request, as returned by `gh pr list --json`.
class PullRequest {
  const PullRequest({
    required this.number,
    required this.title,
    required this.state,
    this.author,
  });

  final int number;
  final String title;
  final String state;
  final String? author;

  @override
  bool operator ==(Object other) =>
      other is PullRequest &&
      other.number == number &&
      other.title == title &&
      other.state == state &&
      other.author == author;

  @override
  int get hashCode => Object.hash(number, title, state, author);

  @override
  String toString() => 'PullRequest(#$number, $title)';
}
