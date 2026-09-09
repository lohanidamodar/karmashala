import 'element_capture.dart';

/// What the page reports about an element — either from a user's click while
/// picking, or from resolving a selector.
///
/// Both paths produce the same JSON shape so there is one parser and one set
/// of tests for it.
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

  /// A selector the page verified resolves back to this element, or null when
  /// none could be derived (shadow DOM, for instance). Null means the caller
  /// must fall back to hit-testing by coordinate.
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

/// The user clicked [element].
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
