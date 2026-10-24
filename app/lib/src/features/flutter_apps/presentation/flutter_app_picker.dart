import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../application/attached_apps.dart';
import '../application/flutter_app_ui_providers.dart';
import 'flutter_app_forget_dialog.dart';

/// Where each app came from, in the fewest words that still say it.
String describeAppDiscovery(AppDiscovery discovery) => switch (discovery) {
  AppDiscovery.uriFile => 'started here',
  AppDiscovery.toolingDaemon => 'flutter run on this machine',
  AppDiscovery.deviceLog => 'announced on a device',
  AppDiscovery.byHand => 'attached by hand',
};

/// An app's second line: how it was found, then how old that is or why
/// nothing answers. The first two survive the ellipsis in a 272px panel.
String describePickerDetail(AttachedApp app, DateTime now) {
  final found = describeAppDiscovery(app.discovery);
  return switch (app.reachability) {
    AppReachability.attached =>
      '$found · found ${describeAge(now.difference(app.observedAt))}',
    AppReachability.unchecked => '$found · not asked yet',
    _ => '$found · ${app.detail ?? 'nothing answers on ${app.printedUri}'}',
  };
}

IconData _glyphOf(AttachedApp app) => !app.isAttached
    ? AppIcons.linkBreak
    : switch (app.discovery) {
        AppDiscovery.deviceLog => AppIcons.deviceMobile,
        AppDiscovery.toolingDaemon => AppIcons.terminal,
        AppDiscovery.byHand => AppIcons.linkSimple,
        AppDiscovery.uriFile => AppIcons.play,
      };

/// **Which app the panel is about**, when there is more than one: one row
/// naming the selected app, and the app's own two-line menu under it —
/// answering apps first, the rest muted with Forget. The row is the same
/// height however many apps there are, so the console keeps the panel.
class FlutterAppPicker extends ConsumerWidget {
  const FlutterAppPicker({
    required this.registry,
    required this.selectedId,
    super.key,
  });

  final FlutterAppRegistry registry;
  final String? selectedId;

  static const _select = 'select:';
  static const _forget = 'forget:';
  static const _forgetAll = 'forget-all';
  static const _forgetSome = 'forget-some';

  /// Answering, every other one, and the menu entries that list them.
  static List<PopupMenuEntry<String>> itemsFor(
    FlutterAppRegistry registry,
    String? selectedId,
    DateTime now,
  ) {
    final groups = flutterAppPickerGroups(registry);
    return [
      if (groups.answering.isNotEmpty) DesktopMenuHeader<String>('Answering'),
      for (final app in groups.answering)
        DesktopMenuDetailItem<String>(
          value: '$_select${app.id}',
          label: app.label ?? app.id,
          detail: describePickerDetail(app, now),
          detailMaxLines: 1,
          icon: _glyphOf(app),
          selected: app.id == selectedId,
        ),
      if (groups.quiet.isNotEmpty) ...[
        if (groups.answering.isNotEmpty) const DesktopMenuDivider(),
        DesktopMenuHeader<String>('Not answering'),
        for (final app in groups.quiet)
          DesktopMenuDetailItem<String>.live(
            value: '$_select${app.id}',
            child: _QuietRow(
              app: app,
              detail: describePickerDetail(app, now),
              selected: app.id == selectedId,
              forgetValue: '$_forget${app.id}',
            ),
          ),
        const DesktopMenuDivider(),
        if (groups.quiet.length > 1)
          DesktopMenuItem<String>(
            value: _forgetSome,
            label: 'Choose which to forget…',
            icon: AppIcons.listChecks,
          ),
        DesktopMenuItem<String>(
          value: _forgetAll,
          label: 'Forget all not answering',
          icon: AppIcons.trash,
          destructive: true,
        ),
      ],
    ];
  }

  Future<void> _run(BuildContext context, WidgetRef ref, String value) async {
    final apps = ref.read(attachedAppsProvider.notifier);
    try {
      if (value.startsWith(_select)) {
        ref
            .read(selectedFlutterAppIdProvider.notifier)
            .select(value.substring(_select.length));
      } else if (value.startsWith(_forget)) {
        await apps.forget(value.substring(_forget.length));
      } else if (value == _forgetAll) {
        final quiet = flutterAppPickerGroups(registry).quiet;
        if (!await confirmForgetAll(context, quiet.length)) return;
        for (final app in quiet) {
          await apps.forget(app.id);
        }
      } else if (value == _forgetSome) {
        final now = ref.read(clockProvider).nowUtc();
        final picked = await chooseAppsToForget(
          context,
          flutterAppPickerGroups(registry).quiet,
          detailOf: (app) => describePickerDetail(app, now),
        );
        for (final id in picked ?? const <String>{}) {
          await apps.forget(id);
        }
      }
    } on DataRefused catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('Forget: ${error.message}')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final now = ref.watch(clockProvider).nowUtc();
    final selected = selectedId == null ? null : registry.byId(selectedId!);
    final count = registry.apps.length;
    final name = selected == null
        ? 'Choose an app'
        : selected.label ?? selected.id;

    return Builder(
      builder: (anchor) => Semantics(
        button: true,
        label: 'Flutter app: $name, $count apps',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('flutter-app-picker'),
          onTap: () async {
            final picked = await showDesktopMenuUnder<String>(
              anchor,
              itemsFor(registry, selectedId, now),
            );
            if (picked != null && context.mounted) {
              await _run(context, ref, picked);
            }
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Chrome.menuRowTall),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs,
              ),
              child: Row(
                children: [
                  Icon(
                    selected == null ? AppIcons.caretDown : _glyphOf(selected),
                    size: Chrome.icon,
                    color: selected?.isAttached ?? false
                        ? semantic.idle
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (selected != null)
                          Text(
                            describePickerDetail(selected, now),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Insets.xs),
                  _Count(count),
                  const Icon(AppIcons.caretDown, size: Chrome.iconAction),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How many apps the menu holds, so a closed picker still says there are
/// others.
class _Count extends StatelessWidget {
  const _Count(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xsm,
        vertical: Insets.xxs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// A row in the muted group: the app, and its own Forget at the end.
class _QuietRow extends StatelessWidget {
  const _QuietRow({
    required this.app,
    required this.detail,
    required this.selected,
    required this.forgetValue,
  });

  final AttachedApp app;
  final String detail;
  final bool selected;
  final String forgetValue;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: DesktopMenuDetailRow(
          label: app.label ?? app.id,
          detail: detail,
          detailMaxLines: 1,
          icon: AppIcons.linkBreak,
          selected: selected,
          // Muted: still a choice, but not one that answers.
          enabled: false,
        ),
      ),
      IconButton(
        tooltip: 'Forget ${app.label ?? app.id}',
        icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
        visualDensity: VisualDensity.compact,
        // Closes the menu with this answer, as a row of its own would.
        onPressed: () => Navigator.of(context).pop(forgetValue),
      ),
    ],
  );
}
