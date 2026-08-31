import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/companion/application/companion_providers.dart';
import '../../features/companion/presentation/companion_settings_screen.dart';
import '../../features/companion/presentation/host_switcher_bar.dart';
import '../../features/companion/presentation/inbox_screen.dart';
import '../../features/companion/presentation/link_banner.dart';
import '../../features/companion/presentation/pairing/pairing_screen.dart';
import '../../features/companion/presentation/session_list_screen.dart';
import '../theme/app_icons.dart';

/// The phone shell: pairing until a host exists, then three tabs — Sessions,
/// Inbox, Settings — under a persistent connection banner. Compact-breakpoint
/// layout (CLAUDE.md §6): bottom navigation, no rail, no panes.
class CompanionShell extends ConsumerStatefulWidget {
  const CompanionShell({super.key});

  @override
  ConsumerState<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends ConsumerState<CompanionShell> {
  int _tab = 0;

  static const _titles = ['Sessions', 'Inbox', 'Settings'];

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
      appBar: AppBar(title: Text(_titles[_tab])),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Which desktop these sessions belong to, above the tab body but
            // below the outage banner — an unreachable host is the more
            // urgent fact of the two.
            const LinkBanner(),
            if (_tab == 0) const HostSwitcherBar(),
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
            icon: Icon(AppIcons.chatCircle),
            label: 'Sessions',
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
