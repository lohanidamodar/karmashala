import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/tab_progress.dart';

/// A tab's progress in its glyph's slot: a ring filled as far as the work has
/// got and a `3/8` beside it, or a warning mark once it ended with failures.
class TabProgressMark extends StatelessWidget {
  const TabProgressMark({required this.progress, super.key});

  final TabProgress progress;

  @override
  Widget build(BuildContext context) {
    final size = UiDensity.of(context).iconSmall;
    final scheme = Theme.of(context).colorScheme;
    final total = progress.total;
    final Widget mark;
    if (progress.running) {
      mark = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator(
              value: total > 0 ? progress.done / total : null,
              strokeWidth: 2,
            ),
          ),
          if (total > 0) ...[
            const SizedBox(width: Insets.tight),
            Text(
              '${progress.done}/$total',
              style: Chrome.tabLabel.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      );
    } else {
      mark = Icon(
        AppIcons.warning,
        size: size,
        color: SemanticColors.of(context).failure,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: Tooltip(
        message: progress.label,
        // Its own node: merged into the chip's, the count would be lost in
        // the title.
        child: Semantics(
          container: true,
          label: progress.label,
          child: ExcludeSemantics(child: mark),
        ),
      ),
    );
  }
}
