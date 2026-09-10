import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../application/device_logcat_session.dart';
import 'package:karmashala_devices/devices.dart';

/// Whether the logcat view under the picture is open. Outside the widget, so
/// closing it disposes the session and a surface switch finds it as left.
class DeviceLogcatOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final deviceLogcatOpenProvider = NotifierProvider<DeviceLogcatOpen, bool>(
  DeviceLogcatOpen.new,
);

/// **The device's log, under its picture.** Collapsed it is one strip that
/// costs nothing: the session is `autoDispose`, so no view, no `logcat`.
class DeviceLogcatSection extends ConsumerWidget {
  const DeviceLogcatSection({required this.device, super.key});

  /// The device the pane is showing. Null while there is none, which is when
  /// the strip disables itself rather than disappearing.
  final AndroidDevice? device;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(deviceLogcatOpenProvider);
    final serial = device?.serial;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        _Strip(device: device, open: open),
        // Nothing below the strip until it is opened, and nothing watching the
        // session provider either — that is what keeps a closed view free.
        if (open && serial != null)
          SizedBox(height: 220, child: _Logcat(serial: serial)),
      ],
    );
  }
}

class _Strip extends ConsumerWidget {
  const _Strip({required this.device, required this.open});

  final AndroidDevice? device;
  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final enabled = device?.isReady ?? false;
    return InkWell(
      onTap: enabled
          ? () => ref.read(deviceLogcatOpenProvider.notifier).toggle()
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm,
        ),
        child: Row(
          children: [
            Icon(
              AppIcons.article,
              size: Chrome.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                device == null
                    ? 'Logcat — no device'
                    : 'Logcat — ${device!.displayName}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: enabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              open ? AppIcons.caretDown : AppIcons.caretUp,
              size: Chrome.iconSmall,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _Logcat extends ConsumerStatefulWidget {
  const _Logcat({required this.serial});

  final String serial;

  @override
  ConsumerState<_Logcat> createState() => _LogcatState();
}

class _LogcatState extends ConsumerState<_Logcat> {
  /// What one scroll view holds. A second bound above the tail's own: this is
  /// what the drawing isolate pays for on a device that logs in a loop.
  static const int visibleLines = 400;

  final _package = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Opening the view is the act that starts the stream. Nothing starts it
    // behind a closed strip, and nothing restarts it on a tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(deviceLogcatSessionProvider(widget.serial)).start();
    });
  }

  @override
  void dispose() {
    _package.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(deviceLogcatSessionProvider(widget.serial));
    final now = ref.watch(clockProvider).nowUtc();
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Controls(session: session, package: _package),
          Expanded(child: _Lines(session: session)),
          _Status(session: session, now: now),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.session, required this.package});

  final DeviceLogcatSession session;
  final TextEditingController package;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Insets.md, 0, Insets.sm, Insets.xs),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: package,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Package, e.g. com.example.app',
            ),
            // Submit rather than keystroke: pinning to a package respawns
            // `logcat --pid`, so per character is a process per keystroke.
            onSubmitted: session.filterByPackage,
          ),
        ),
        const SizedBox(width: Insets.sm),
        DropdownButton<LogLevel>(
          value: session.minLevel,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: [
            for (final level in LogLevel.values)
              DropdownMenuItem(
                value: level,
                child: Text(
                  level.code,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
          onChanged: (level) =>
              level == null ? null : session.setMinLevel(level),
        ),
        IconButton(
          tooltip: session.streaming ? 'Stop reading' : 'Start reading',
          icon: Icon(
            session.streaming ? AppIcons.stopCircle : AppIcons.playCircle,
            size: Chrome.iconAction,
          ),
          onPressed: session.streaming ? session.stop : session.start,
        ),
        IconButton(
          tooltip: 'Clear what is on screen',
          icon: const Icon(AppIcons.trash, size: Chrome.iconAction),
          onPressed: session.clear,
        ),
      ],
    ),
  );
}

class _Lines extends StatelessWidget {
  const _Lines({required this.session});

  final DeviceLogcatSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = session.lines(limit: _LogcatState.visibleLines);
    final problem = session.problem;
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Insets.md),
          child: Text(
            // Three different nothings, never one word for all: a filter that
            // matches nothing, a stream nobody started, and a quiet device.
            problem ??
                (session.starting
                    ? 'Attaching to the log…'
                    : session.streaming
                    ? 'Attached — nothing has been logged at '
                          '${session.minLevel.code} or above yet.'
                    : 'Not reading. Start to attach to this device’s log.'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      // Newest at the bottom, and cheap: the list is built from the end so a
      // chatty device does not re-lay-out everything above the fold.
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      itemCount: lines.length,
      itemBuilder: (context, index) =>
          _Line(entry: lines[lines.length - 1 - index]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.entry});

  final LogcatEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = SemanticColors.of(context);
    final colour = switch (entry.level) {
      LogLevel.error || LogLevel.fatal => semantic.attention,
      LogLevel.warning => semantic.working,
      LogLevel.verbose || LogLevel.debug => theme.colorScheme.onSurfaceVariant,
      LogLevel.info => theme.colorScheme.onSurface,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${entry.level.code} ${entry.tag}: ',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colour,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: entry.message,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: colour,
              ),
            ),
          ],
        ),
        maxLines: 3,
      ),
    );
  }
}

/// §19 at the line the reading is on: how old this tail is, and what it lost.
class _Status extends StatelessWidget {
  const _Status({required this.session, required this.now});

  final DeviceLogcatSession session;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.xs,
        Insets.md,
        Insets.sm,
      ),
      child: Text(
        _words(),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _words() {
    final parts = <String>[];
    final startedAt = session.startedAt;
    parts.add(
      startedAt == null
          ? 'Not attached'
          : 'Attached ${describeDriveAge(now.difference(startedAt))}',
    );
    final lastAt = session.lastLineAt;
    // Never "no lines yet" as a time: a stream that has produced nothing has no
    // last line, and a zero there would read as a line that just arrived.
    parts.add(
      lastAt == null
          ? 'no line yet'
          : 'last line ${describeDriveAge(now.difference(lastAt))}',
    );
    parts.add('${session.kept} kept');
    // Counted, and shown whenever it is not zero — a tail that quietly dropped
    // its oldest lines looks exactly like one that never saw them.
    if (session.dropped > 0) parts.add('${session.dropped} dropped');
    if (session.packageFilter != null) parts.add('only ${session.packageFilter}');
    return parts.join(' · ');
  }
}
