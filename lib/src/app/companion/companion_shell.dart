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
import '../theme/design_tokens.dart';

/// The phone shell: pairing until a host exists, then three tabs — Projects,
/// Inbox, Settings — under a persistent connection banner. Compact-breakpoint
/// layout (CLAUDE.md §6): bottom navigation, no rail, no panes.
///
/// The first tab is named for what it lists. It was "Sessions" and showed
/// projects *and* sessions in one flat list, which is exactly the confusion
/// Loop 82 was asked to fix: the tab is the top of the hierarchy, and the
/// hierarchy's top is projects.
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
      appBar: AppBar(
        // Grown with the text scale rather than fixed: a 200% title does not
        // fit a 56px bar, and the screen's own name is the worst thing to clip.
        toolbarHeight: Touch.appBarOf(context),
        title: Text(_titles[_tab]),
      ),
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
