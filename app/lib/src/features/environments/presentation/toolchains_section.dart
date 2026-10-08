import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_session/resume.dart' show describeAge;
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../settings/presentation/settings_section.dart';
import '../../settings/presentation/settings_theme.dart';
import '../application/environments_controller.dart';
import '../application/toolchain_readings.dart';
import '../domain/toolchain.dart';

/// **Settings → Machines: what each machine can actually build.**
///
/// It replaced a catalogue of project kinds that measured nothing. What a kind
/// is built with is still here — as the line under the thing being measured,
/// where it says something about *this* machine rather than about the world.
///
/// §19 throughout: every row carries its reading's age, nothing polls, and a
/// machine nobody has asked says so rather than reading as empty.
class ToolchainsSection extends ConsumerStatefulWidget {
  const ToolchainsSection({super.key});

  @override
  ConsumerState<ToolchainsSection> createState() => _ToolchainsSectionState();
}

class _ToolchainsSectionState extends ConsumerState<ToolchainsSection> {
  @override
  void initState() {
    super.initState();
    // Opening the page measures the machines that cost nothing but a process.
    // An SSH host is somebody else's machine and is dialled only when asked.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureLocal());
  }

  Future<void> _measureLocal() async {
    if (!mounted) return;
    for (final environment in ref.read(environmentsControllerProvider)) {
      if (environment.kind == EnvironmentKind.ssh) continue;
      if (ref
          .read(toolchainReadingsProvider.notifier)
          .hasLooked(environment.id)) {
        continue;
      }
      await measureToolchains(ProviderScope.containerOf(context), environment);
      if (!mounted) return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final environments = ref.watch(environmentsControllerProvider);
    if (environments.isEmpty) return const SizedBox.shrink();
    ref.watch(toolchainReadingsProvider);

    return SettingsSection(
      title: 'BUILD TOOLING',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsNote(
            'SSH hosts are only checked when you press Check.',
          ),
          for (final environment in environments)
            _EnvironmentToolchains(environment: environment),
        ],
      ),
    );
  }
}

class _EnvironmentToolchains extends ConsumerWidget {
  const _EnvironmentToolchains({required this.environment});

  final ExecutionEnvironment environment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final readings = ref
        .watch(toolchainReadingsProvider.notifier)
        .cached(environment.id);
    final running = ref
        .watch(toolchainProbesRunningProvider)
        .contains(environment.id);
    final now = ref.read(clockProvider).nowUtc();
    final readAt = readings.values.isEmpty
        ? null
        : readings.values.first.readAt;

    // One ruled entry per machine, like every list on a settings page.
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ref.watch(environmentLabelForIdProvider(environment.id)),
                  style: SettingsStyles.rowLabel(context),
                ),
              ),
              // Gives way before the button does, at the narrowest window
              // with large text.
              Flexible(
                child: Text(
                  running
                      ? 'asking…'
                      // Never "nothing found": a machine nobody asked has said
                      // nothing at all, and the two read differently (§19).
                      : readAt == null
                      ? 'never checked'
                      : 'checked ${describeAge(now.difference(readAt))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: Insets.xs),
              TextButton.icon(
                onPressed: running
                    ? null
                    : () => measureToolchains(
                        ProviderScope.containerOf(context),
                        environment,
                        force: true,
                      ),
                icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
                label: Text(readAt == null ? 'Check' : 'Check again'),
              ),
            ],
          ),
          if (readings.isEmpty && !running)
            Padding(
              padding: const EdgeInsets.only(left: Insets.sm),
              child: Text(
                'Nothing has been asked of this machine yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final toolchain in Toolchain.values)
              _ToolchainRow(toolchain: toolchain, reading: readings[toolchain]),
        ],
      ),
    );
  }
}

class _ToolchainRow extends StatelessWidget {
  const _ToolchainRow({required this.toolchain, required this.reading});

  final Toolchain toolchain;
  final ToolchainReading? reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    final status = reading?.status ?? ToolchainStatus.unknown;
    final (icon, colour) = switch (status) {
      ToolchainStatus.present || ToolchainStatus.presentVersionUnknown => (
        AppIcons.checkCircle,
        semantic.idle,
      ),
      ToolchainStatus.missing => (
        AppIcons.minusCircle,
        scheme.onSurfaceVariant,
      ),
      ToolchainStatus.notApplicable => (
        AppIcons.minusCircle,
        scheme.onSurfaceVariant,
      ),
      ToolchainStatus.unknown => (AppIcons.warningCircle, semantic.neutral),
      ToolchainStatus.refused => (AppIcons.warningCircle, semantic.attention),
    };
    final said = switch (status) {
      ToolchainStatus.present => reading?.version ?? toolchain.label,
      ToolchainStatus.presentVersionUnknown =>
        'there, and would not say which version',
      ToolchainStatus.missing => 'not found',
      ToolchainStatus.notApplicable => 'not on this kind of machine',
      ToolchainStatus.unknown => 'could not be asked',
      ToolchainStatus.refused => 'found here, and refused',
    };

    return Padding(
      padding: const EdgeInsets.only(left: Insets.sm, top: Insets.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xxs),
            child: Icon(icon, size: Chrome.icon, color: colour),
          ),
          const SizedBox(width: Insets.xs),
          SizedBox(
            width: 110,
            child: Text(toolchain.label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  said,
                  style: theme.textTheme.bodySmall?.copyWith(color: colour),
                ),
                Text(
                  toolchain.purpose,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // The reason matters for both: one says why it could not be
                // asked, the other why what it found must not be run.
                if (reading?.detail case final String detail
                    when status == ToolchainStatus.unknown ||
                        status == ToolchainStatus.refused)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
