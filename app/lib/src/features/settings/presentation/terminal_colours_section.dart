import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_terminal_core/grid.dart';
import 'package:karmashala_terminal_runtime/themes.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:xterm2/xterm.dart' show TerminalTheme;

import '../../terminal/application/terminal_theme_controller.dart';
import '../../terminal/presentation/terminal_theme_colors.dart';
import '../application/settings_controller.dart';
import '../application/settings_tab.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'settings_theme.dart';

/// Settings → Appearance → Terminal colours: every built-in scheme drawn in
/// its own colours, grouped by the ground it sits on, then a Ghostty or Warp
/// theme file. One setting (`terminalThemeSource`) holds whichever is chosen,
/// so picking one is un-picking the others, and every pane repaints at once.
class TerminalColoursSection extends ConsumerWidget {
  const TerminalColoursSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(terminalThemeSourceProvider);
    final scheme = ref.watch(terminalSchemeProvider);
    final importing = source != null && !TerminalSchemes.isSchemeSource(source);
    final controller = ref.read(settingsControllerProvider.notifier);

    void choose(TerminalScheme picked) =>
        controller.setTerminalThemeSource(TerminalSchemes.sourceFor(picked));

    Widget group(String label, String? help, List<TerminalScheme> schemes) =>
        _SchemeGroup(
          label: label,
          help: help,
          schemes: schemes,
          // An imported theme is in force: no built-in card is.
          selected: importing ? null : scheme,
          onSelected: choose,
        );

    final fixed = [
      for (final s in TerminalSchemes.all)
        if (!s.matchesApp) s,
    ];
    return SettingsSection(
      title: SettingsAnchor.terminalTheme.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          group('Match app', 'Follows light and dark, and the accent.', const [
            TerminalSchemes.matchApp,
          ]),
          group('Dark', null, [
            for (final s in fixed)
              if (s.isLight == false) s,
          ]),
          group('Light', null, [
            for (final s in fixed)
              if (s.isLight == true) s,
          ]),
          const _ImportedThemeRows(),
        ],
      ),
    );
  }
}

/// One group of schemes under a ruled label: the cards wrap to the width they
/// are given, so the group needs no measuring.
class _SchemeGroup extends StatelessWidget {
  const _SchemeGroup({
    required this.label,
    required this.help,
    required this.schemes,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final String? help;
  final List<TerminalScheme> schemes;
  final TerminalScheme? selected;
  final ValueChanged<TerminalScheme> onSelected;

  @override
  Widget build(BuildContext context) {
    final help = this.help;
    return SettingsRuled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: SettingsStyles.rowLabel(context)),
          if (help != null)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xxs),
              child: Text(help, style: SettingsStyles.rowHelp(context)),
            ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              for (final s in schemes)
                _SchemeCard(
                  scheme: s,
                  selected: s.id == selected?.id,
                  onTap: () => onSelected(s),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A scheme as it will look: its sixteen colours as two strips (normal over
/// bright) on its own background, a prompt and an `ls` in its colours, and its
/// name under that. Drawn with the same [terminalThemeFor] the panes use, so
/// the preview cannot drift from the terminal. The scheme's colours are data
/// and used as they are; only the card's frame wears the app's tokens.
class _SchemeCard extends StatelessWidget {
  const _SchemeCard({
    required this.scheme,
    required this.selected,
    required this.onTap,
  });

  final TerminalScheme scheme;
  final bool selected;
  final VoidCallback onTap;

  static const double width = 196;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tones = SurfaceTones.of(context);
    final t = terminalThemeFor(theme, scheme.palette);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Terminal colours: ${scheme.name}',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: Material(
          type: MaterialType.transparency,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
            side: BorderSide(
              color: selected ? colors.primary : tones.pressed,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: tones.hover,
            child: Padding(
              padding: const EdgeInsets.all(Insets.xs + Insets.xxs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SchemePreview(theme: t),
                  const SizedBox(height: Insets.xs + 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          scheme.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SettingsStyles.control(context),
                        ),
                      ),
                      if (selected)
                        Icon(
                          AppIcons.checkCircle,
                          size: Chrome.iconSmall,
                          color: colors.primary,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SchemePreview extends StatelessWidget {
  const _SchemePreview({required this.theme});

  final TerminalTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final normal = [
      t.black,
      t.red,
      t.green,
      t.yellow,
      t.blue,
      t.magenta,
      t.cyan,
      t.white,
    ];
    final bright = [
      t.brightBlack,
      t.brightRed,
      t.brightGreen,
      t.brightYellow,
      t.brightBlue,
      t.brightMagenta,
      t.brightCyan,
      t.brightWhite,
    ];
    final base = MonoStyles.small.copyWith(color: t.foreground, height: 1.4);
    final bold = base.copyWith(fontWeight: FontWeight.w700);

    Widget strip(List<Color> colours) => Row(
      children: [
        for (final c in colours)
          Expanded(child: Container(height: 8, color: c)),
      ],
    );

    Widget line(List<InlineSpan> spans) => Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(Radii.sm - 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Insets.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            strip(normal),
            strip(bright),
            const SizedBox(height: Insets.xs + 2),
            line([
              TextSpan(
                text: '~/app',
                style: bold.copyWith(color: t.blue),
              ),
              TextSpan(
                text: ' main',
                style: base.copyWith(color: t.magenta),
              ),
              const TextSpan(text: r' $ ls'),
            ]),
            line([
              TextSpan(
                text: 'src/',
                style: bold.copyWith(color: t.blue),
              ),
              const TextSpan(text: ' notes.md '),
              TextSpan(
                text: 'run.sh',
                style: bold.copyWith(color: t.green),
              ),
            ]),
            line([
              TextSpan(
                text: 'error',
                style: bold.copyWith(color: t.red),
              ),
              const TextSpan(text: ' 2 '),
              TextSpan(
                text: 'warn',
                style: base.copyWith(color: t.yellow),
              ),
              TextSpan(
                text: ' # note',
                style: base.copyWith(color: t.brightBlack),
              ),
              const TextSpan(text: ' '),
              // The cursor, as a block of its colour.
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(width: 6, height: 12, color: t.cursor),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// A theme file from Ghostty or Warp, instead of a built-in scheme. The
/// identity is stored, not the colours, so editing the file is picked up.
class _ImportedThemeRows extends ConsumerWidget {
  const _ImportedThemeRows();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(settingsControllerProvider.notifier);
    final source = ref.watch(terminalThemeSourceProvider);
    final importing = source != null && !TerminalSchemes.isSchemeSource(source);
    final discovered = ref.watch(discoveredTerminalThemesProvider);
    final loaded = ref.watch(importedTerminalThemeProvider);

    // A vanished theme file would leave the dropdown on a value no item
    // carries, which makes it throw.
    final ids = discovered.map((t) => t.id).toSet();
    final value = importing && ids.contains(source) ? source : null;

    TextStyle? errorStyle() =>
        theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: 'From Ghostty or Warp',
          help: discovered.isEmpty
              ? 'No Ghostty or Warp themes found on this machine.'
              : 'A theme file on this machine, in place of the schemes above.',
          control: DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: value,
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final t in discovered)
                DropdownMenuItem(
                  value: t.id,
                  child: Text('${t.name}  ·  ${t.format.name}'),
                ),
            ],
            onChanged: (id) {
              // "None" puts an imported theme back on Match app, and leaves a
              // built-in scheme alone.
              if (id == null && !importing) return;
              controller.setTerminalThemeSource(id);
            },
          ),
        ),
        // Said under the row it is about, in its own tone, not as a loose red
        // line between rows.
        if (importing && value == null)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              'The saved theme is no longer where it was; using Match app.',
              style: errorStyle(),
            ),
          ),
        if (loaded is ThemeLoadError)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              '${loaded.reason} Using Match app.',
              style: errorStyle(),
            ),
          ),
        if (loaded is ThemeLoadOk && loaded.notes.isNotEmpty)
          SettingsNote(loaded.notes.join(' ')),
      ],
    );
  }
}

/// Terminal → Font's pointer to where terminal colours are chosen now: the
/// scheme in force, and a way there. One place per control.
class TerminalColoursPointerRow extends ConsumerWidget {
  const TerminalColoursPointerRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref.watch(terminalSchemeLabelProvider);
    return SettingsRow(
      label: 'Colours',
      help: '$label. Chosen under Appearance.',
      control: OutlinedButton(
        onPressed: () => ref
            .read(settingsTabSectionProvider.notifier)
            .reveal(SettingsTarget.anchor(SettingsAnchor.terminalTheme)),
        child: const Text('Open Appearance'),
      ),
    );
  }
}
