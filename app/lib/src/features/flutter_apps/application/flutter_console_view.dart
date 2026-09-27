import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:riverpod/riverpod.dart';

import 'app_console_feed.dart';
import 'flutter_app_ui_providers.dart';

/// One app's console view: the query, the selected match, and where the view
/// was cleared. Kept outside the pane so switching apps or remounting keeps it.
class FlutterConsoleView {
  const FlutterConsoleView({
    this.query = const AppLogQuery(),
    this.currentMatch,
    this.clearedLink,
    this.clearedBefore = 0,
  });

  final AppLogQuery query;

  /// Sequence number of the selected match.
  final int? currentMatch;

  /// The feed [clearedBefore] numbers lines on — a re-attach starts from zero.
  final Object? clearedLink;
  final int clearedBefore;

  @override
  bool operator ==(Object other) =>
      other is FlutterConsoleView &&
      other.query == query &&
      other.currentMatch == currentMatch &&
      identical(other.clearedLink, clearedLink) &&
      other.clearedBefore == clearedBefore;

  @override
  int get hashCode => Object.hash(
    query,
    currentMatch,
    identityHashCode(clearedLink),
    clearedBefore,
  );
}

/// Console views by app id.
class FlutterConsoleViews extends Notifier<Map<String, FlutterConsoleView>> {
  @override
  Map<String, FlutterConsoleView> build() => const {};

  FlutterConsoleView of(String appId) =>
      state[appId] ?? const FlutterConsoleView();

  void _put(String appId, FlutterConsoleView view) =>
      state = {...state, appId: view};

  void setQuery(String appId, AppLogQuery query) {
    final view = of(appId);
    if (view.query == query) return;
    // A match picked under another query means nothing under this one.
    _put(
      appId,
      FlutterConsoleView(
        query: query,
        clearedLink: view.clearedLink,
        clearedBefore: view.clearedBefore,
      ),
    );
  }

  void selectMatch(String appId, int? sequence) {
    final view = of(appId);
    _put(
      appId,
      FlutterConsoleView(
        query: view.query,
        currentMatch: sequence,
        clearedLink: view.clearedLink,
        clearedBefore: view.clearedBefore,
      ),
    );
  }

  /// Hides what is there now. The app's buffer, and what an MCP call reads, keep
  /// it.
  void clear(String appId, AppConsoleFeed link) => _put(
    appId,
    FlutterConsoleView(
      query: of(appId).query,
      clearedLink: link,
      clearedBefore: link.consoleAppended,
    ),
  );
}

final flutterConsoleViewsProvider =
    NotifierProvider<FlutterConsoleViews, Map<String, FlutterConsoleView>>(
      FlutterConsoleViews.new,
    );

final flutterConsoleViewProvider = Provider.family<FlutterConsoleView, String>(
  (ref, appId) => ref.watch(
    flutterConsoleViewsProvider.select(
      (views) => views[appId] ?? const FlutterConsoleView(),
    ),
  ),
);

/// One per feed: a re-attach numbers its lines from zero again.
final _filterCacheProvider = Provider.autoDispose
    .family<AppLogFilterCache, String>((ref, appId) {
      ref.watch(appConsoleFeedProvider(appId));
      return AppLogFilterCache();
    });

/// The console under its view, recomputed per batch but searching only the
/// new lines. Null when the app has no feed.
final flutterConsoleFilterProvider = Provider.autoDispose
    .family<AppLogFilterResult?, String>((ref, appId) {
      ref.watch(flutterAppConsoleTickProvider(appId));
      final view = ref.watch(flutterConsoleViewProvider(appId));
      final feed = ref.watch(appConsoleFeedProvider(appId));
      if (feed == null) return null;
      return feed.filterConsole(
        ref.watch(_filterCacheProvider(appId)),
        view.query,
        hideBefore: identical(view.clearedLink, feed) ? view.clearedBefore : 0,
      );
    });
