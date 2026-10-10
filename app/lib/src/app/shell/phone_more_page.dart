import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/presentation/usage_tab/usage_tab_state.dart';
import '../../features/agents/presentation/usage_tab/usage_tab_view.dart';
import '../../features/workflows/presentation/workflows_tab_view.dart';
import '../../features/notes/presentation/notes_view.dart';
import '../../features/explorer/presentation/agents_lens.dart';
import '../../features/remote/presentation/machines_section.dart';
import '../../features/settings/presentation/about_page.dart';
import '../../features/settings/presentation/settings_layout.dart';
import '../../features/settings/presentation/settings_tab_view.dart';
import '../../features/settings/presentation/settings_theme.dart';
import '../../features/stores/presentation/stores_tab_view.dart';
import '../../features/todos/presentation/todos_view.dart';
import 'activity_strip.dart' show ActivityStrip;
import 'phone_log_page.dart';
import 'shell_area.dart';
import 'running_tab_view.dart';
import 'phone_routes.dart';
import 'phone_shell.dart' show PhoneTabsScope;

/// The phone's More tab: what the desktop's strip keeps below its areas.
/// Each opens as a full page inside the tab, so the bottom bar stays.
class PhoneMoreList extends StatelessWidget {
  const PhoneMoreList({super.key});

  static (String, IconData, WidgetBuilder) _entry(PhoneMoreEntry entry) =>
      switch (entry) {
        // Its header is the page's one row: back, the name and the filter.
        PhoneMoreEntry.todos => (
          'Todos',
          AppIcons.listChecks,
          (_) => const PaneTitleOverride(child: TodosView()),
        ),
        // Every session, the Dashboard's first tab's place before it.
        PhoneMoreEntry.sessions => (
          'Sessions',
          ActivityStrip.iconFor(ShellArea.sessions),
          (_) => const _HeadedPage(child: AgentsPage()),
        ),
        PhoneMoreEntry.usage => ('Usage', AppIcons.chartBar, _usage),
        PhoneMoreEntry.stores => (
          'Stores',
          AppIcons.package,
          (_) => const PaneTitleOverride(child: StoresTabView()),
        ),
        PhoneMoreEntry.workflows => (
          kWorkflowsTitle,
          AppIcons.flowArrow,
          (_) => const PaneTitleOverride(child: WorkflowsTabView()),
        ),
        PhoneMoreEntry.running => (
          'Running',
          AppIcons.listMagnifyingGlass,
          (_) => const PaneTitleOverride(child: RunningTabView()),
        ),
        // Its header is the page's one row: back, the name and its actions.
        PhoneMoreEntry.notes => (
          'Notes',
          AppIcons.note,
          (_) => const PaneTitleOverride(child: NotesView()),
        ),
        PhoneMoreEntry.settings => (
          'Settings',
          AppIcons.gearSix,
          (_) => const _HeadedPage(child: SettingsTabView()),
        ),
        PhoneMoreEntry.machines => (
          'Machines',
          AppIcons.wifiHigh,
          (_) => const _HeadedPage(
            child: _SettingsSectionPage(child: MachinesSection()),
          ),
        ),
        PhoneMoreEntry.log => (
          'Log',
          AppIcons.article,
          (_) => const PaneTitleOverride(child: PhoneLogPage()),
        ),
        PhoneMoreEntry.about => (
          'About',
          AppIcons.info,
          (_) => const _HeadedPage(
            child: _SettingsSectionPage(child: AboutSection()),
          ),
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

  // Its header is the page's one row: back, the name and the range.
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

/// A More entry's page: the view the desktop shows in a tab, under one row
/// of back, its name and its own controls (round 86). The view's header
/// draws that row from the [PageHeaderScope], or [_HeadedPage] does.
class _MorePage extends StatelessWidget {
  const _MorePage({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: PageHeaderScope(
        title: title,
        onBack: () => Navigator.of(context).maybePop(),
        child: child,
      ),
    ),
  );
}

/// A page with no header of its own, under the More page's one row.
class _HeadedPage extends StatelessWidget {
  const _HeadedPage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ?PageHeaderBar.maybeFor(context),
      Expanded(child: PageHeaderScope.claimed(child: child)),
    ],
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
