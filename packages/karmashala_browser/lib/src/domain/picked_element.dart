import 'element_capture.dart';

/// What the page reports about an element, from a pick or from a resolved
/// selector. One JSON shape for both, so there is one parser and one set of tests.
class PickedElement {
  const PickedElement({
    required this.tagName,
    required this.box,
    required this.url,
    required this.title,
    this.selector,
    this.elementId,
    this.classNames = const [],
    this.clientX,
    this.clientY,
  });

  /// A selector the page verified resolves back to this element, or null (shadow
  /// DOM) — null means the caller must fall back to hit-testing by coordinate.
  final String? selector;
  final String tagName;
  final String? elementId;
  final List<String> classNames;

  /// Viewport coordinates of the click, kept for the coordinate fallback.
  final double? clientX;
  final double? clientY;

  /// The element's rectangle in page coordinates.
  final ElementBox box;
  final String url;
  final String title;

  static PickedElement fromJson(Map<String, Object?> json) => PickedElement(
    selector: json['selector'] as String?,
    tagName: json['tagName']?.toString() ?? 'unknown',
    elementId: json['id'] as String?,
    classNames: [
      for (final name in (json['classNames'] as List? ?? const []))
        name.toString(),
    ],
    clientX: (json['clientX'] as num?)?.toDouble(),
    clientY: (json['clientY'] as num?)?.toDouble(),
    box: ElementBox.fromJson(
      (json['box'] as Map<String, Object?>?) ?? const {},
    ),
    url: json['url']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
  );
}

/// The outcome of one pick: an element, or the user backing out.
sealed class PickOutcome {
  const PickOutcome();
}

class PickSelected extends PickOutcome {
  const PickSelected(this.element);
  final PickedElement element;
}

/// The user pressed Escape.
class PickCancelled extends PickOutcome {
  const PickCancelled();
}

/// Parses one payload from the picker binding.
PickOutcome parsePickPayload(Map<String, Object?> json) {
  if (json['ok'] == true) return PickSelected(PickedElement.fromJson(json));
  return const PickCancelled();
}
