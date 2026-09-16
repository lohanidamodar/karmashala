import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../../notes/application/composer_draft.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import '../application/android_app_discovery.dart';
import '../application/attached_apps.dart';
import '../application/flutter_app_ui_providers.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

/// The debug console for the Flutter app under development, and the two buttons
/// worth having. Looks when it opens and when asked, never on a timer (§19).
class FlutterAppPane extends ConsumerStatefulWidget {
  const FlutterAppPane({super.key});

  @override
  ConsumerState<FlutterAppPane> createState() => _FlutterAppPaneState();
}

class _FlutterAppPaneState extends ConsumerState<FlutterAppPane> {
  @override
  void initState() {
    super.initState();
    // After the first frame: opening a surface must not make that frame wait on
    // a directory read.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(attachedAppsProvider.notifier).look();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watching this is what puts a `logcat` reader on each connected device.
    // Nothing else subscribes, so a closed pane reads no device at all.
    ref.watch(androidAppDiscoveryProvider);
    final registry = ref.watch(attachedAppsProvider);
    final selectedId = ref.watch(paneFlutterAppIdProvider);
    final selected = selectedId == null ? null : registry.byId(selectedId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusRow(registry: registry),
        const Divider(height: 1),
        if (registry.apps.length > 1) ...[
          _AppList(registry: registry, selectedId: selectedId),
          const Divider(height: 1),
        ],
        if (selected != null) ...[
          _Actions(app: selected),
          const Divider(height: 1),
        ],
        Expanded(
          child: selected == null
              ? _NothingAttached(registry: registry)
              : _Console(app: selected),
        ),
      ],
    );
  }
}

/// What we know, and how old it is.
class _StatusRow extends ConsumerWidget {
  const _StatusRow({required this.registry});

  final FlutterAppRegistry registry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    // Four states, four colours; the neutral one covers the two we cannot speak
    // to, "not looked" and "could not look".
    final colour = switch (registry) {
      FlutterAppRegistry(discoveryFailure: final String _) => semantic.failure,
      FlutterAppRegistry(hasLooked: false) => theme.colorScheme.outline,
      _ when registry.attached.isNotEmpty => semantic.idle,
      _ when registry.apps.isNotEmpty => semantic.attention,
      _ => theme.colorScheme.outline,
    };
    final age = registry.lookedAt == null
        ? null
        : describeAge(ref.watch(clockProvider).nowUtc().difference(registry.lookedAt!));

    return PaneStatusRow(
      color: colour,
      label: age == null
          ? describeRegistry(registry)
          : '${describeRegistry(registry)}  ·  checked $age',
      action: IconButton(
        onPressed: () => ref.read(attachedAppsProvider.notifier).look(),
        icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.iconAction),
        tooltip: 'Look again',
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Where each app came from, in the fewest words that still say it.
String describeAppDiscovery(AppDiscovery discovery) => switch (discovery) {
  AppDiscovery.uriFile => 'started here',
  AppDiscovery.toolingDaemon => 'flutter run on this machine',
  AppDiscovery.deviceLog => 'announced on a device',
  AppDiscovery.byHand => 'attached by hand',
};

/// The apps, when there is more than one to choose between.
class _AppList extends ConsumerWidget {
  const _AppList({required this.registry, required this.selectedId});

  final FlutterAppRegistry registry;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final now = ref.watch(clockProvider).nowUtc();
    return Column(
      children: [
        for (final app in registry.apps)
          ListTile(
            dense: true,
            selected: app.id == selectedId,
            leading: Icon(
              app.isAttached ? AppIcons.play : AppIcons.linkBreak,
              size: Chrome.iconAction,
            ),
            title: Text(app.label ?? app.id, style: theme.textTheme.bodySmall),
            // How it was found and how old that reading is, before the address:
            // those two survive the ellipsis in a 272px panel.
            subtitle: Text(
              '${describeAppDiscovery(app.discovery)} · found '
              '${describeAge(now.difference(app.observedAt))}  ·  '
              '${app.isAttached ? app.printedUri : app.detail ?? 'nothing answers on ${app.printedUri}'}',
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => ref
                .read(selectedFlutterAppIdProvider.notifier)
                .select(app.id),
          ),
      ],
    );
  }
}

/// Hot reload, restart, pick — and the honest refusals.
class _Actions extends ConsumerStatefulWidget {
  const _Actions({required this.app});

  final AttachedApp app;

  @override
  ConsumerState<_Actions> createState() => _ActionsState();
}

class _ActionsState extends ConsumerState<_Actions> {
  bool _busy = false;
  bool _picking = false;

  Future<void> _run(String verb, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on FlutterAppException catch (error) {
      // Out loud, and in the failure's own words: a dropped failure here looks
      // exactly like a reload that silently did nothing.
      _say('$verb: ${error.message}');
    } on Object catch (error) {
      _say('$verb failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final selection = await ref
          .read(attachedAppsProvider.notifier)
          .pickWidget(widget.app.id);
      if (!mounted) return;
      _say(selection.toPromptText());
      await Clipboard.setData(ClipboardData(text: selection.toPromptText()));
    } on FlutterAppException catch (error) {
      _say(error.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final apps = ref.read(attachedAppsProvider.notifier);
    final app = widget.app;
    final theme = Theme.of(context);
    // The reason a button is off, in the place a user looks for it.
    final reloadOff = !app.isAttached
        ? 'Not attached.'
        : app.canHotReload
        ? null
        : 'No Flutter tool is attached to this app, so there is nothing to '
              'recompile the sources.';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Insets.xs,
        vertical: Insets.xs,
      ),
      child: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _Action(
            icon: AppIcons.arrowsClockwise,
            label: 'Hot reload',
            disabledReason: reloadOff,
            busy: _busy,
            onPressed: () => _run('Hot reload', () => apps.hotReload(app.id)),
          ),
          _Action(
            icon: AppIcons.arrowCounterClockwise,
            label: 'Restart',
            disabledReason: reloadOff,
            busy: _busy,
            onPressed: () => _run('Restart', () => apps.hotRestart(app.id)),
          ),
          _Action(
            icon: AppIcons.handTap,
            label: _picking ? 'Tap the app…' : 'Pick widget',
            disabledReason: app.isAttached ? null : 'Not attached.',
            busy: _picking,
            onPressed: _pick,
          ),
          _Action(
            icon: app.isAttached ? AppIcons.linkBreak : AppIcons.trash,
            label: app.isAttached ? 'Detach' : 'Forget',
            busy: _busy,
            onPressed: () => _run(
              app.isAttached ? 'Detach' : 'Forget',
              () => app.isAttached
                  ? apps.detach(app.id)
                  : apps.forget(app.id),
            ),
          ),
          if (app.widgetLocations == WidgetLocationSupport.absent)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
              child: Text(
                'This build carries no widget locations.',
                style: theme.textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.disabledReason,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  /// Why this is off. Rendered as the tooltip, because a disabled button with
  /// no explanation is the same fault as a confident false statement.
  final String? disabledReason;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final off = disabledReason != null || busy;
    return Tooltip(
      message: disabledReason ?? label,
      child: TextButton.icon(
        onPressed: off ? null : onPressed,
        icon: Icon(icon, size: Chrome.iconAction),
        label: Text(label),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          textStyle: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}

/// The empty state, which is four different empty states.
class _NothingAttached extends ConsumerWidget {
  const _NothingAttached({required this.registry});

  final FlutterAppRegistry registry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // For everything but another machine's run there genuinely is no remedy;
    // the button below is the one case that is left.
    final hint = ref.read(attachedAppsProvider.notifier).attachHint;
    return PanePlaceholder(
      icon: AppIcons.play,
      message: '${describeRegistry(registry)}\n\n$hint',
      action: const _AttachByAddress(),
    );
  }
}

/// The escape hatch: an address the developer already has on screen.
class _AttachByAddress extends ConsumerStatefulWidget {
  const _AttachByAddress();

  @override
  ConsumerState<_AttachByAddress> createState() => _AttachByAddressState();
}

class _AttachByAddressState extends ConsumerState<_AttachByAddress> {
  final _address = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(attachedAppsProvider.notifier).attach(_address.text);
      if (mounted) setState(() => _open = false);
    } on FlutterAppException catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return TextButton.icon(
        onPressed: () => setState(() => _open = true),
        icon: const Icon(AppIcons.linkSimple, size: Chrome.iconAction),
        label: const Text('Attach by address'),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: TextField(
        controller: _address,
        autofocus: true,
        enabled: !_busy,
        style: Theme.of(context).textTheme.bodySmall,
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'http://127.0.0.1:53119/AbCdEf=/',
          helperText: 'The address "flutter run" printed.',
        ),
        onSubmitted: (_) => _attach(),
      ),
    );
  }
}

/// One app's debug console.
class _Console extends ConsumerWidget {
  const _Console({required this.app});

  /// The newest lines rendered at once — bounded separately from the buffer,
  /// which is what an MCP call pages through.
  static const int visibleLines = 500;

  final AttachedApp app;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Subscribed for the repaint; the lines are read off the link.
    ref.watch(flutterAppConsoleTickProvider(app.id));
    final records = ref
        .read(attachedAppsProvider.notifier)
        .linkFor(app.id)
        ?.tail(limit: visibleLines);

    if (records == null || records.isEmpty) {
      return PanePlaceholder(
        icon: AppIcons.article,
        message: app.isAttached
            // Deliberately not "no output": what the app said before we
            // attached is not ours to report (§19).
            ? 'Nothing since Karmashala attached. Whatever the app said before '
                  'that is not in this console.'
            : 'Not attached, so there is nothing to show.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ConsoleActions(app: app, records: records),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.sm,
              vertical: Insets.xs,
            ),
            itemCount: records.length,
            itemBuilder: (context, index) =>
                _ConsoleLine(record: records[records.length - 1 - index]),
          ),
        ),
      ],
    );
  }
}

/// What can be done with what the app said.
class _ConsoleActions extends ConsumerWidget {
  const _ConsoleActions({required this.app, required this.records});

  final AttachedApp app;
  final List<AppLogRecord> records;

  /// The newest error, or null when the app has not thrown.
  AppLogRecord? get _newestError {
    for (final record in records.reversed) {
      if (record.isError) return record;
    }
    return null;
  }

  /// Puts the error in the session's message box — offered, not sent, and
  /// nothing notifies: an exception pushed mid-turn is Karmashala deciding.
  void _offer(BuildContext context, WidgetRef ref, AppLogRecord error) {
    final sessionId = ref.read(focusedSessionIdProvider);
    final text = <String>[
      'The running Flutter app (${app.label ?? app.id}) reported this:',
      '',
      error.message,
      if (error.detail != null) error.detail!,
    ].join('\n');
    if (sessionId == null) {
      Clipboard.setData(ClipboardData(text: text));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('No session is focused — copied to the clipboard.'),
        ),
      );
      return;
    }
    ref.read(composerDraftProvider.notifier).queue(sessionId, text);
    ref.read(selectedSessionIdProvider.notifier).select(sessionId);
    final title =
        ref.read(sessionDaoProvider).getById(sessionId)?.title ?? 'the session';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Waiting in $title\'s message box.')),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = _newestError;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              error == null
                  ? '${records.length} lines'
                  : '${records.length} lines · newest error: ${error.message}',
              style: theme.textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (error != null)
            _Action(
              icon: AppIcons.paperPlaneRight,
              label: 'Offer error to session',
              onPressed: () => _offer(context, ref, error),
            ),
        ],
      ),
    );
  }
}

class _ConsoleLine extends StatelessWidget {
  const _ConsoleLine({required this.record});

  final AppLogRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final colour = switch (record.source) {
      AppLogSource.flutterError || AppLogSource.stderr => semantic.failure,
      AppLogSource.lifecycle => theme.colorScheme.onSurfaceVariant,
      AppLogSource.developerLog => theme.colorScheme.tertiary,
      AppLogSource.stdout => theme.colorScheme.onSurface,
    };
    final origin = switch (record.source) {
      AppLogSource.stdout => 'out',
      AppLogSource.stderr => 'err',
      AppLogSource.developerLog => record.loggerName?.isNotEmpty == true
          ? record.loggerName!
          : 'log',
      AppLogSource.flutterError => 'error',
      AppLogSource.lifecycle => '·',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              origin,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: SelectableText(
              record.detail == null
                  ? record.message
                  : '${record.message}\n${record.detail}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colour,
                fontFamily: kMonoFamily,
              ),
            ),
          ),
          // History, marked: the VM service replays its buffer to every new
          // subscriber, so the top of this console is the app's past.
          if (record.beforeAttach)
            Padding(
              padding: const EdgeInsets.only(left: Insets.xs),
              child: Text(
                'before attach',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
