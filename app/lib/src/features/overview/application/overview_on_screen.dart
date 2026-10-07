import 'package:riverpod/riverpod.dart';

/// How many Agent dashboards are drawn now: one while its tab is shown, none
/// when it is closed or behind another tab, which never builds it.
class OverviewOnScreen extends Notifier<int> {
  @override
  int build() => 0;

  void add() => state++;

  void remove() {
    if (!ref.mounted) return;
    if (state > 0) state--;
  }
}

final overviewOnScreenProvider = NotifierProvider<OverviewOnScreen, int>(
  OverviewOnScreen.new,
);
