/// A GitHub issue, as returned by `gh issue list --json`.
class Issue {
  const Issue({required this.number, required this.title, required this.state});

  final int number;
  final String title;
  final String state;

  @override
  bool operator ==(Object other) =>
      other is Issue &&
      other.number == number &&
      other.title == title &&
      other.state == state;

  @override
  int get hashCode => Object.hash(number, title, state);

  @override
  String toString() => 'Issue(#$number, $title)';
}
