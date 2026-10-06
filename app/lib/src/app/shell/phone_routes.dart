/// Where the phone shell shows what the desktop opens as a workbench tab. Its
/// own file, so a verb in `workbench_tabs.dart` need not import the shell.
library;

import 'package:riverpod/riverpod.dart';

/// The More tab's pages, in list order.
enum PhoneMoreEntry {
  overview,
  usage,
  stores,
  running,
  notes,
  settings,
  machines,
  log,
  about,
}

/// What the phone shell can bring on screen, for an act that started outside
/// its tabs: quick open's dialog, a keyboard shortcut, a deep link.
abstract interface class PhoneShellRoutes {
  /// Raises the session page, the workbench at compact.
  void showWorkbench();

  /// Brings the Projects tab to the front.
  void showProjects();

  /// Brings the Inbox tab to the front.
  void showInbox();

  /// Opens [entry] as the only page over More's list.
  void showMore(PhoneMoreEntry entry);
}

/// Holds the phone shell's routes while it is the shell on screen. Read at the
/// moment of acting, never watched: which shell is up is not state to draw.
class PhoneShellRouter {
  PhoneShellRoutes? _shown;

  PhoneShellRoutes? get current => _shown;

  void attach(PhoneShellRoutes routes) => _shown = routes;

  void detach(PhoneShellRoutes routes) {
    if (identical(_shown, routes)) _shown = null;
  }
}

final phoneShellRouterProvider = Provider<PhoneShellRouter>(
  (ref) => PhoneShellRouter(),
);

/// Whether the phone shows the desktop's workbench over its tabs — where a
/// session opens (owner's answer 5). Here rather than in the shell, so the
/// notifications can ask whether a session is on screen, and open one before
/// the shell is built.
class PhoneWorkbenchController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

final phoneWorkbenchProvider = NotifierProvider<PhoneWorkbenchController, bool>(
  PhoneWorkbenchController.new,
);
