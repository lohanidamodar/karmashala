import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// `+12 −3`, in the diff colours. The `+` and `−` carry the meaning on their
/// own, so a reader who cannot tell the two hues apart still reads it (§5), and
/// the pair is announced as one phrase rather than two loose numbers.
class DiffCountLabel extends StatelessWidget {
  const DiffCountLabel({required this.added, required this.removed, super.key});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final semantic = SemanticColors.of(context);
    return Semantics(
      container: true,
      label: '$added added, $removed removed',
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            if (added > 0)
              TextSpan(
                text: '+$added',
                style: TextStyle(color: semantic.diffAdded),
              ),
            if (added > 0 && removed > 0) const TextSpan(text: ' '),
            if (removed > 0)
              TextSpan(
                text: '−$removed',
                style: TextStyle(color: semantic.diffRemoved),
              ),
          ],
        ),
        style: MonoStyles.small,
        maxLines: 1,
      ),
    );
  }
}
