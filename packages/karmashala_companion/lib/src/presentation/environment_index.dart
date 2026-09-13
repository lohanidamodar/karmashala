import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_environments.dart';
import 'companion_chrome.dart';

/// The machines behind one desktop, as rows to pick from.
///
/// Drawn only when there are two or more: a phone whose desktop runs one
/// machine is not asked to choose between it and nothing.
class EnvironmentIndex extends StatelessWidget {
  const EnvironmentIndex({
    required this.environments,
    required this.onPick,
    this.header,
    super.key,
  });

  final List<CompanionEnvironment> environments;
  final void Function(String key) onPick;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final offset = header == null ? 0 : 1;
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: companionListInsets(
        context,
        const EdgeInsets.only(bottom: companionFabGutter),
      ),
      itemCount: environments.length + offset,
      separatorBuilder: (context, index) =>
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
      itemBuilder: (context, index) {
        if (index < offset) return header!;
        final environment = environments[index - offset];
        return EnvironmentRow(
          environment: environment,
          onTap: () => onPick(environment.key),
        );
      },
    );
  }
}

class EnvironmentRow extends StatelessWidget {
  const EnvironmentRow({
    required this.environment,
    required this.onTap,
    super.key,
  });

  final CompanionEnvironment environment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final density = UiDensity.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: density.isTouch
            ? const BoxConstraints(minHeight: Touch.target)
            : null,
        padding: EdgeInsets.symmetric(
          horizontal: density.padX,
          vertical: density.padY,
        ),
        child: Row(
          children: [
            Icon(
              environmentGlyphFor(environment.kind),
              size: density.icon,
              color: scheme.onSurfaceVariant,
            ),
            SizedBox(width: density.isTouch ? Insets.md : Insets.sm),
            Expanded(
              child: Text(
                environment.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: density.title(theme),
              ),
            ),
            Text(describeEnvironmentHolding(environment), style: density.muted(theme)),
            const SizedBox(width: Insets.xs),
            Icon(
              AppIcons.caretRight,
              size: density.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// What a machine is holding, in projects. Sessions are the rows behind it, so
/// the count a person picks by is the one they think in.
String describeEnvironmentHolding(CompanionEnvironment environment) =>
    environment.projects == 1
    ? '1 project'
    : '${environment.projects} projects';

/// A machine's glyph from the kind the desktop named, and a neutral one when
/// it named none — never a kind guessed from a label.
IconData environmentGlyphFor(String? kind) => switch (kind) {
  'ssh' => AppIcons.globe,
  'wsl' => AppIcons.terminalWindow,
  'windowsNative' || 'localPosix' => AppIcons.terminal,
  _ => AppIcons.folders,
};
