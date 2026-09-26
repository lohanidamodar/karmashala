import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';

/// The phone shell: pairing until a host exists, then Projects, Inbox and
/// Settings under a connection banner. Bottom navigation, no rail, no panes.
class CompanionShell extends ConsumerStatefulWidget {
  const CompanionShell({super.key});

  @override
  ConsumerState<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends ConsumerState<CompanionShell> {
  int _tab = 0;

  static const _titles = ['Projects', 'Inbox', 'Usage', 'Notes', 'Settings'];
  static const _usageTab = 2;
  static const _notesTab = 3;

  /// The most of the body the banner and desktop strip take before scrolling.
  static const _chromeShare = 0.5;

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(companionPairingProvider);
    final inboxCount = ref.watch(companionInboxCountProvider);

    // A companion with no host is the first thing a user ever sees, so the
    // unpaired state is a real screen, not an empty tab.
    if (pairing.isLoading && !pairing.hasValue) {
      return const Scaffold(
        body: Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
      );
    }
    if (pairing.asData?.value == null) return const PairingScreen();

    const inboxIcon = Icon(AppIcons.tray);
    // Gives way to the search field the keyboard came up for.
    final showSwitcher = _tab == 0 && !companionKeyboardSqueezed(context);
    return Scaffold(
      appBar: companionAppBar(context, title: Text(_titles[_tab])),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The chrome above the tab scrolls within a share of the body,
              // so an outage at 200% text cannot push the tab off a landscape
              // phone.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * _chromeShare,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Which desktop these sessions belong to, below the
                      // outage banner: an unreachable host is more urgent.
                      const LinkBanner(),
                      if (showSwitcher) const HostSwitcherBar(),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    const SessionListScreen(),
                    const InboxScreen(),
                    // Built only while shown: usage is asked when the tab
                    // opens, and an offstage tab would ask at launch.
                    if (_tab == _usageTab)
                      const UsageScreen()
                    else
                      const SizedBox.shrink(),
                    // Asked when the tab opens, for the same reason.
                    if (_tab == _notesTab)
                      const NotesScreen()
                    else
                      const SizedBox.shrink(),
                    const CompanionSettingsScreen(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(AppIcons.folder),
            selectedIcon: Icon(AppIcons.folderOpen),
            label: 'Projects',
          ),
          NavigationDestination(
            icon: inboxCount == 0
                ? inboxIcon
                : Badge.count(count: inboxCount, child: inboxIcon),
            label: 'Inbox',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.circleHalf),
            label: 'Usage',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.note),
            label: 'Notes',
          ),
          const NavigationDestination(
            icon: Icon(AppIcons.gearSix),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
