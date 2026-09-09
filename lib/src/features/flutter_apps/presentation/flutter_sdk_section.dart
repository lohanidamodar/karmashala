import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../../core/util/file_picking.dart';
import '../../environments/application/environments_controller.dart';
import '../../environments/domain/execution_environment.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/flutter_sdk_readings.dart';
import '../domain/flutter_sdk.dart';

/// Settings → Environments: **the Flutter SDK a person names for an
/// environment**, when PATH there does not mention one.
///
/// The Flutter loop refuses in words when `where flutter.bat` / `command -v
/// flutter` answers nothing — which is the right refusal, and was the whole
/// answer. Somebody with an SDK unpacked outside PATH had nowhere to say so.
///
/// One row per execution environment, because that is the unit the question is
/// asked in: an SDK on the Windows host says nothing about a WSL distribution,
/// and §17 is the reason it must not.
///
/// **Two different things on each row, kept apart.** The field is a *setting* —
/// a statement, stored in `Settings.flutterSdkPaths`, never rewritten by
/// discovery (§20's third rule). The line under it is a *reading* — what
/// happened when the path was last run, with its age beside it. Nothing here
/// measures on its own: opening this page spawns nothing, and Check is the
/// button that costs a process. An SSH environment is not probed unasked at
/// all, because probing it means dialling somebody's machine.
class FlutterSdkSection extends ConsumerWidget {
  const FlutterSdkSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final environments = ref.watch(environmentsControllerProvider);
    final paths = ref.watch(
      settingsControllerProvider.select((s) => s.flutterSdkPaths),
    );
    if (environments.isEmpty) return const SizedBox.shrink();

    return SettingsSection(
      title: 'FLUTTER SDK',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Only needed where Flutter is not on that environment\'s PATH. '
            'A path set here is used instead of the PATH lookup, and is never '
            'changed by "Find local".',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          for (final environment in environments)
            _FlutterSdkRow(
              // Keyed by environment, not by position. Discovery can insert a
              // distribution above an existing one, and an unkeyed row would
              // hand its state — the text in the field — to whichever
              // environment moved into its slot.
              key: ValueKey(environment.id),
              environment: environment,
              stored: paths[environment.id],
            ),
        ],
      ),
    );
  }
}

class _FlutterSdkRow extends ConsumerStatefulWidget {
  const _FlutterSdkRow({
    required this.environment,
    required this.stored,
    super.key,
  });

  final ExecutionEnvironment environment;

  /// The path this environment is currently set to, or null for PATH.
  final String? stored;

  @override
  ConsumerState<_FlutterSdkRow> createState() => _FlutterSdkRowState();
}

class _FlutterSdkRowState extends ConsumerState<_FlutterSdkRow> {
  late final TextEditingController _path = TextEditingController(
    text: widget.stored ?? '',
  );
  bool _checking = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  /// Browse is the convenience; the field is the way out — the same order, and
  /// for the same measured reason, as `AgentPathSection._browse`. It is also
  /// the only order that works here: a WSL or SSH path is spelled for *that*
  /// machine and no Windows file dialog can reach it.
  Future<void> _browse() async {
    final file = await pickOneFile(what: 'the flutter executable');
    if (file == null) return;
    _path.text = file.path;
    _save(file.path);
  }

  void _save(String path) {
    ref
        .read(settingsControllerProvider.notifier)
        .setFlutterSdkPath(widget.environment.id, path);
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await ref
          .read(flutterSdkReadingsProvider.notifier)
          .readFor(widget.environment, force: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watched, so a Check on this row — or a save anywhere, which empties the
    // held readings — repaints the line below.
    final reading = ref.watch(
      flutterSdkReadingsProvider.select(
        (readings) => readings[widget.environment.id],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.environment.name,
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                widget.stored == null ? 'from PATH' : 'set by you',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _path,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Flutter executable',
                  // Named rather than implied: on Windows the extensionless
                  // file beside it is a POSIX script, and running that is the
                  // §17 disaster.
                  hintText: r'e.g. C:\src\flutter\bin\flutter.bat',
                ),
                onSubmitted: _save,
              );
              final buttons = [
                OutlinedButton.icon(
                  onPressed: () => _save(_path.text),
                  icon: const Icon(AppIcons.check, size: Chrome.icon),
                  label: const Text('Save'),
                ),
                OutlinedButton.icon(
                  onPressed: _browse,
                  icon: const Icon(AppIcons.folderOpen, size: Chrome.icon),
                  label: const Text('Browse'),
                ),
                OutlinedButton.icon(
                  onPressed: _checking ? null : _check,
                  icon: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
                  label: const Text('Check'),
                ),
              ];
              if (constraints.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    field,
                    const SizedBox(height: Insets.xs),
                    Wrap(spacing: Insets.xs, children: buttons),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: Insets.sm),
                  for (final button in buttons) ...[
                    button,
                    const SizedBox(width: Insets.xs),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: Insets.xs),
          _readingLine(context, reading),
        ],
      ),
    );
  }

  Widget _readingLine(BuildContext context, FlutterSdkReading? reading) {
    final theme = Theme.of(context);
    if (reading == null) {
      // Never "no Flutter here": nobody has looked (§19).
      return Text(
        'Not checked yet.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    final now = ref.read(clockProvider).nowUtc();
    final age = describeAge(now.difference(reading.readAt));
    if (reading.isUsable) {
      return Text(
        '${reading.executable}'
        '${reading.version == null ? '' : ' · ${reading.version}'}'
        ' · checked $age',
        style: MonoStyles.small,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Not colour alone: the sentence says it too.
        Icon(
          AppIcons.warning,
          size: Chrome.icon,
          color: theme.colorScheme.error,
        ),
        const SizedBox(width: Insets.xs),
        Expanded(
          child: Text(
            '${reading.reason} (checked $age)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }
}
