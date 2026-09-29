import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/explorer/application/agent_state_providers.dart';
import '../../features/explorer/application/explorer_tree_provider.dart';
import '../../features/explorer/presentation/agents_lens.dart';
import '../../features/explorer/presentation/explorer_panel.dart';
import '../../features/notifications/application/attention_inbox.dart';
import '../../features/notifications/presentation/attention_inbox_view.dart';
import '../../features/sessions/application/session_ui_providers.dart';
import 'activity_strip.dart' show ActivityStrip;
import 'phone_more_page.dart';
import 'phone_top_bar.dart';
import 'shell_area.dart';
import 'shell_compact_bar.dart' show ShellTabSwitcher;
import 'workbench.dart';

/// The phone shell's tabs (owner's decision 5), in bottom-bar order. Devices
/// is never one: a phone has no adb of its own.
enum PhoneTab {
  sessions(ShellArea.sessions),
  projects(ShellArea.projects),
  terminals(ShellArea.terminals),
  inbox(ShellArea.inbox),
  more(null);

  const PhoneTab(this.area);

  /// The strip's area this tab shows; null for More.
  final ShellArea? area;

  String get label => area?.label ?? 'More';

  IconData get icon => switch (area) {
    final area? => ActivityStrip.iconFor(area),
    null => AppIcons.dotsThree,
  };
}

/// The tab in front. A provider, not widget state, so a rotation through the
/// desktop layout and back lands on the same tab.
class PhoneTabController extends Notifier<PhoneTab> {
  @override
  PhoneTab build() => PhoneTab.sessions;

  void select(PhoneTab tab) => state = tab;
}

final phoneTabProvider = NotifierProvider<PhoneTabController, PhoneTab>(
  PhoneTabController.new,
);

/// Whether the phone shows the desktop's workbench over its tabs — where a
/// session opens (owner's answer 5), until Stage 2 gives the phone its own.
class PhoneWorkbenchController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

final phoneWorkbenchProvider = NotifierProvider<PhoneWorkbenchController, bool>(
  PhoneWorkbenchController.new,
);

/// Shows the workbench on a phone. Does nothing a wider window can see.
void openPhoneWorkbench(WidgetRef ref) =>
    ref.read(phoneWorkbenchProvider.notifier).open();

/// **The compact shell** (Stage 1 step 7): the host switcher on top, the tabs
/// in a bottom bar, and the workbench over them when a session opens.
/// `AppShell` picks it by width, never platform.
class PhoneShell extends ConsumerStatefulWidget {
  const PhoneShell({super.key});

  @override
  ConsumerState<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends ConsumerState<PhoneShell> {
  final _tabKeys = {for (final tab in PhoneTab.values) tab: GlobalKey()};
  final _moreNavigator = GlobalKey<NavigatorState>();

  void _pick(PhoneTab tab) {
    if (ref.read(phoneTabProvider) == tab) {
      _backToTop(tab);
      return;
    }
    ref.read(phoneTabProvider.notifier).select(tab);
  }

  /// A second tap on the tab in front: More goes back to its list, a list
  /// scrolls back to its top.
  void _backToTop(PhoneTab tab) {
    if (tab == PhoneTab.more) {
      _moreNavigator.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    final root = _tabKeys[tab]?.currentContext;
    if (root == null) return;
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (position.axis == Axis.vertical &&
            position.pixels > position.minScrollExtent) {
          found = position;
          return;
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildElements(visit);
    final position = found;
    if (position == null) return;
    final duration = Motion.of(context).emphasisIn;
    if (duration == Duration.zero) {
      position.jumpTo(position.minScrollExtent);
    } else {
      position.animateTo(
        position.minScrollExtent,
        duration: duration,
        curve: Motion.standard,
      );
    }
  }

  Widget _body(PhoneTab tab) => switch (tab) {
    PhoneTab.sessions => const AgentsPage(),
    PhoneTab.projects => const ExplorerPanel(terminals: false),
    PhoneTab.terminals => ExplorerTreeView(source: terminalsTreeProvider),
    PhoneTab.inbox => const AttentionInboxView(),
    PhoneTab.more => Navigator(
      key: _moreNavigator,
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => const PhoneMoreList()),
    ),
  };

  @override
  Widget build(BuildContext context) {
    // A session picked anywhere — a row, the Inbox, a notification — is a
    // request to see it, and the workbench is where it is drawn.
    ref.listen(selectedSessionIdProvider, (was, now) {
      if (now != null && now != was) openPhoneWorkbench(ref);
    });
    ref.listen(selectedImportedSessionIdProvider, (was, now) {
      if (now != null && now != was) openPhoneWorkbench(ref);
    });
    final tab = ref.watch(phoneTabProvider);
    final workbench = ref.watch(phoneWorkbenchProvider);
    final tabs = Scaffold(
      appBar: const PhoneTopBar(),
      body: ColoredBox(
        color: SurfaceTones.of(context).side,
        child: NavigatorPopHandler(
          enabled: tab == PhoneTab.more && !workbench,
          onPopWithResult: (_) => _moreNavigator.currentState?.maybePop(),
          child: IndexedStack(
            index: tab.index,
            children: [
              for (final each in PhoneTab.values)
                KeyedSubtree(
                  key: _tabKeys[each],
                  child: KeyedSubtree(
                    // Scroll offsets are kept by it across a rotation.
                    key: PageStorageKey<String>('phone-tab-${each.name}'),
                    child: _body(each),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _PhoneBottomBar(tab: tab, onPick: _pick),
    );
    return PopScope(
      canPop: !workbench,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && workbench) {
          ref.read(phoneWorkbenchProvider.notifier).close();
        }
      },
      child: Stack(
        children: [
          // Kept mounted under the workbench, so every tab keeps its place.
          Positioned.fill(
            child: Offstage(
              offstage: workbench,
              child: TickerMode(enabled: !workbench, child: tabs),
            ),
          ),
          if (workbench) const Positioned.fill(child: _PhoneWorkbench()),
        ],
      ),
    );
  }
}

/// Sessions and Inbox carry what waits on the user, as the strip does.
class _PhoneBottomBar extends ConsumerWidget {
  const _PhoneBottomBar({required this.tab, required this.onPick});

  final PhoneTab tab;
  final ValueChanged<PhoneTab> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsYou = ref.watch(needsYouCountProvider);
    final asks = ref.watch(inboxAskCountProvider);
    final news = ref.watch(inboxHasUnseenUpdateProvider);
    final attention = SemanticColors.of(context).attention;
    final scheme = Theme.of(context).colorScheme;
    Widget icon(PhoneTab each) {
      final glyph = Icon(each.icon);
      return switch (each) {
        PhoneTab.sessions when needsYou > 0 => Badge.count(
          count: needsYou,
          backgroundColor: attention,
          child: glyph,
        ),
        PhoneTab.inbox when asks > 0 => Badge.count(
          count: asks,
          backgroundColor: attention,
          child: glyph,
        ),
        PhoneTab.inbox when news => Badge(
          smallSize: Chrome.dot,
          backgroundColor: scheme.onSurfaceVariant,
          child: glyph,
        ),
        _ => glyph,
      };
    }

    String label(PhoneTab each) => switch (each) {
      PhoneTab.sessions when needsYou > 0 => 'Sessions, $needsYou need you',
      PhoneTab.inbox when asks > 0 => 'Inbox, $asks to answer',
      PhoneTab.inbox when news => 'Inbox, new updates',
      _ => each.label,
    };

    return NavigationBar(
      selectedIndex: tab.index,
      onDestinationSelected: (index) => onPick(PhoneTab.values[index]),
      destinations: [
        for (final each in PhoneTab.values)
          NavigationDestination(
            icon: icon(each),
            label: each.label,
            tooltip: label(each),
          ),
      ],
    );
  }
}

/// The desktop's workbench at phone width (owner's answer 5): untuned until
/// Stage 2. Back returns to the tabs; the workbench keeps what it shows.
class _PhoneWorkbench extends ConsumerWidget {
  const _PhoneWorkbench();

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(
      leading: BackButton(
        onPressed: () => ref.read(phoneWorkbenchProvider.notifier).close(),
      ),
      titleSpacing: 0,
      title: const Padding(
        padding: EdgeInsetsDirectional.only(end: Insets.md),
        child: ShellTabSwitcher(),
      ),
    ),
    body: const SafeArea(top: false, child: WorkbenchView()),
  );
}
