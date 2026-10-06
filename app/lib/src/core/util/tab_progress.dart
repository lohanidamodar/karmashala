/// How far a page's own work has got, for its tab's header: any document
/// tab whose page does work in the background (Stores now; Usage or Logs
/// could) reports one.
class TabProgress {
  const TabProgress({
    required this.running,
    this.done = 0,
    this.total = 0,
    this.failed = 0,
  });

  /// Whether the work is under way.
  final bool running;

  /// Parts finished of [total]; a [total] of 0 is not known yet.
  final int done;
  final int total;

  /// Parts whose last attempt failed; said once the work has ended.
  final int failed;

  /// Nothing to say: the tab wears its own glyph.
  bool get quiet => !running && failed == 0;

  /// What a screen reader is told in place of the mark.
  String get label => running
      ? (total > 0 ? 'Working, $done of $total' : 'Working')
      : '$failed failed';

  @override
  bool operator ==(Object other) =>
      other is TabProgress &&
      other.running == running &&
      other.done == done &&
      other.total == total &&
      other.failed == failed;

  @override
  int get hashCode => Object.hash(running, done, total, failed);
}
