import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/presentation/usage_tab/usage_tab_state.dart';
import '../../features/agents/presentation/usage_tab/usage_tab_view.dart';
import '../../features/notes/presentation/notes_view.dart';
import '../../features/overview/presentation/overview_tab_view.dart';
import '../../features/remote/presentation/machines_section.dart';
import '../../features/settings/presentation/about_page.dart';
import '../../features/settings/presentation/settings_layout.dart';
import '../../features/settings/presentation/settings_tab_view.dart';
import '../../features/settings/presentation/settings_theme.dart';
import '../../features/stores/presentation/stores_tab_view.dart';
import 'phone_log_page.dart';
import 'phone_routes.dart';
import 'phone_shell.dart' show PhoneTabsScope;

/// The phone's More tab: what the desktop's strip keeps below its areas.
/// Each opens as a full page inside the tab, so the bottom bar stays.
class PhoneMoreList extends StatelessWidget {
  const PhoneMoreList({super.key});

  static (String, IconData, WidgetBuilder) _entry(PhoneMoreEntry entry) =>
      switch (entry) {
        PhoneMoreEntry.overview => (
          'Overview',
          AppIcons.squaresFour,
          (_) => const PaneTitleOverride(child: OverviewTabView()),
        ),
        PhoneMoreEntry.usage => ('Usage', AppIcons.chartBar, _usage),
        PhoneMoreEntry.stores => (
          'Stores',
          AppIcons.package,
          (_) => const PaneTitleOverride(child: StoresTabView()),
        ),
        // The page's app bar names it, so its own header drops the name.
        PhoneMoreEntry.notes => (
          'Notes',
          AppIcons.note,
          (_) => const PaneTitleOverride(child: NotesView()),
        ),
        PhoneMoreEntry.settings => (
          'Settings',
          AppIcons.gearSix,
          (_) => const SettingsTabView(),
        ),
        PhoneMoreEntry.machines => (
          'Machines',
          AppIcons.wifiHigh,
          (_) => const _SettingsSectionPage(child: MachinesSection()),
        ),
        PhoneMoreEntry.log => (
          'Log',
          AppIcons.article,
          (_) => const PhoneLogPage(),
        ),
        PhoneMoreEntry.about => (
          'About',
          AppIcons.info,
          (_) => const _SettingsSectionPage(child: AboutSection()),
        ),
      };

  /// [entry]'s page, as its row pushes it.
  static Route<void> routeFor(PhoneMoreEntry entry) {
    final (label, _, page) = _entry(entry);
    return _route(label, page);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(automaticallyImplyLeading: false, title: const Text('More')),
    body: ListView(
      children: [
        for (final entry in PhoneMoreEntry.values) _tile(context, entry),
      ],
    ),
  );

  static Widget _tile(BuildContext context, PhoneMoreEntry entry) {
    final (label, icon, page) = _entry(entry);
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(AppIcons.caretRight),
      onTap: () => Navigator.of(context).push(_route(label, page)),
    );
  }

  // Under the page's app bar, which names it: its own header drops the name.
  static Widget _usage(BuildContext _) =>
      const PaneTitleOverride(child: UsageTabView());

  static Route<void> _route(String title, WidgetBuilder page) =>
      MaterialPageRoute<void>(
        builder: (context) => _MorePage(title: title, child: page(context)),
      );
}

/// More's Usage page, for a link inside the phone's tabs (Settings' "Usage"
/// links); null anywhere else, where the link opens the workbench tab. Read
/// before any await: the link may be gone when it resolves.
void Function({String? accountId})? phoneUsagePageOpener(
  BuildContext context,
  WidgetRef ref,
) {
  if (!PhoneTabsScope.contains(context)) return null;
  final navigator = Navigator.of(context);
  final selection = ref.read(usageTabSelectionProvider.notifier);
  return ({String? accountId}) {
    if (accountId != null) selection.selectAccount(accountId);
    navigator.push(PhoneMoreList._route('Usage', PhoneMoreList._usage));
  };
}

/// A More entry's page: a back arrow and its name over the view the desktop
/// shows in a tab.
class _MorePage extends StatelessWidget {
  const _MorePage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(top: false, child: child),
  );
}

/// One settings section as a page of its own, drawn as Settings draws it.
class _SettingsSectionPage extends StatelessWidget {
  const _SettingsSectionPage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SettingsNarrowScope(
    narrow: true,
    child: SettingsControlsTheme(
      child: ListView(
        padding: const EdgeInsets.all(Insets.lg),
        children: [child],
      ),
    ),
  );
}
