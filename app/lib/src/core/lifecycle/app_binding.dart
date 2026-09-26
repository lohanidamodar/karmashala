/// Which Flutter binding this process runs on.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

/// Initializes the binding, and in a **debug build only** makes it Marionette's
/// — the VM-service extensions an agent drives the app through: read the widget
/// tree, tap, type, scroll, screenshot (see docs/marionette.md).
///
/// `kDebugMode` rather than a flag, for two reasons. The extensions are
/// registered on the VM service, which a release build does not serve at all;
/// and anything that can drive the UI is not a thing to ship switched off and
/// hope. A release build gets the ordinary [WidgetsFlutterBinding], and the
/// branch is constant, so the rest is tree-shaken.
WidgetsBinding ensureAppBinding() => kDebugMode
    ? MarionetteBinding.ensureInitialized()
    : WidgetsFlutterBinding.ensureInitialized();
