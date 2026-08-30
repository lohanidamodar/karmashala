/// A GitHub pull request, as returned by `gh pr list --json`.
class PullRequest {
  const PullRequest({
    required this.number,
    required this.title,
    required this.state,
    this.author,
    this.url,
  });

  final int number;
  final String title;
  final String state;
  final String? author;

  /// The PR's page on the forge. `gh` returns it, so it is used rather than
  /// rebuilt from the remote — a URL the server gave us cannot be wrong about
  /// its own host.
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is PullRequest &&
      other.number == number &&
      other.title == title &&
      other.state == state &&
      other.author == author &&
      other.url == url;

  @override
  int get hashCode => Object.hash(number, title, state, author, url);

  @override
  String toString() => 'PullRequest(#$number, $title)';
}
