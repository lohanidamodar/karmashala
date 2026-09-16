import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_companion/providers.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_companion/widgets.dart';
import 'package:karmashala_companion/pairing.dart';
import 'package:karmashala_ui/icons.dart';

/// The phone shell: pairing until a host exists, then Projects, Inbox and
/// Settings under a connection banner. Bottom navigation, no rail, no panes.
class CompanionShell extends ConsumerStatefulWidget {
  const CompanionShell({super.key});

  @override
  ConsumerState<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends ConsumerState<CompanionShell> {
  int _tab = 0;

  static const _titles = ['Projects', 'Inbox', 'Settings'];

  @override
  Widget build(BuildContext context) {
    final pairing = ref.watch(companionPairingProvider);
    final inboxCount = ref.watch(companionInboxCountProvider);

    // A companion with no host is the first thing a user ever sees, so the
    // unpaired state is a real screen, not an empty tab.
    if (pairing.isLoading && !pairing.hasValue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (pairing.asData?.value == null) return const PairingScreen();

    const inboxIcon = Icon(AppIcons.tray);
    return Scaffold(
      appBar: companionAppBar(context, title: Text(_titles[_tab])),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Which desktop these sessions belong to, below the outage banner — an
            // unreachable host is the more urgent fact of the two.
            const LinkBanner(),
            // Gives way to the search field the keyboard came up for.
            if (_tab == 0 && !companionKeyboardSqueezed(context))
              const HostSwitcherBar(),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: const [
                  SessionListScreen(),
                  InboxScreen(),
                  CompanionSettingsScreen(),
                ],
              ),
            ),
          ],
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
            icon: Icon(AppIcons.gearSix),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
