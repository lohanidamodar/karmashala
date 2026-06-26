# Chitragupta - Agent development environment

## 1. Project Context

This is a Flutter project.

Project summary:

```txt
Agent development environment that works with multiple agent cli, claude code, codex, antigravity. Easily manage sessions across projects, integrate with existing codebases, and provide a unified interface for agent interactions.
```

Primary targets:
- Windows / macOS / Linux
- mobile app will be a remote companion

Primary goals:

- Keep the app clean, maintainable, and production-ready.
- Prefer practical solutions over over-engineering.
- Keep changes small, reviewable, and aligned with the existing structure.
- Make responsive behavior part of each UI change, not a final polish step.

Out of scope unless explicitly requested:

- Large unrelated refactors
- New architecture rewrites
- New packages that duplicate existing project capabilities
- Publishing, deploying, signing, or uploading builds
- Modifying secrets, signing files, API keys, credentials, or production configs

---

## 2. Agent Workflow

Before making changes:

- Understand the request and inspect the relevant files.
- Follow the existing project structure and style.
- Explain a short plan for larger or risky changes.
- Ask for clarification only when the task is ambiguous and a reasonable
  assumption would be risky.
- Prefer small, focused edits over broad rewrites.
- Do not rewrite unrelated code.
- Do not add packages unless they are clearly useful and consistent with the
  project direction.

While making changes:

- Preserve user changes already present in the working tree.
- Keep commits, publishing, deployments, and release builds manual unless the
  user explicitly asks for them.
- Use package and framework APIs instead of ad hoc implementations when the
  project already has a standard way to solve the problem.
- Keep generated or mechanical changes separate from logic changes when possible.

After making changes:

- Explain what changed.
- Mention important files modified.
- Mention assumptions, incomplete work, or verification that could not be run.
- Suggest the next useful step when it naturally follows from the work.

---

## 3. Tech Stack

Update this table for the current project.

| Concern | Choice |
| --- | --- |
| Flutter SDK | `<stable version or project constraint>` |
| Dart SDK | `<version or project constraint>` |
| State management | `<provider / riverpod / bloc / cubit / inherited widgets / other>` |
| Routing | `<go_router>` |
| Persistence | `<shared_preferences / hive / drift / sqlite / secure storage / other>` |
| Networking | `<http>` |
| Localization | `<flutter gen-l10n / intl />` |
| Testing | `flutter_test`, plus project-specific tools |
| Lints | `flutter_lints` or project-specific analyzer rules |
| Code generation | `<none>` |

Dependency rules:

- Prefer the packages already used by the project.
- Add dependencies with `flutter pub add <package>` when possible instead of
  editing dependency constraints by hand.
- Do not add a dependency for trivial helper logic.
- If the project avoids code generation, do not introduce `build_runner`,
  `freezed`, `json_serializable`, generated Riverpod providers, or generated
  adapters without explicit approval.
- If the project uses code generation already, update generated files using the
  established command and include them in verification.

---

## 4. Architecture Principles

Prefer a simple feature-first structure unless the existing project uses a
different pattern.

Recommended structure for medium and large apps:

```txt
lib/
├── app/
│   ├── app.dart
│   ├── router.dart
│   └── theme.dart
├── core/
│   ├── constants/
│   ├── layout/
│   ├── utils/
│   └── widgets/
├── features/
│   └── feature_name/
│       ├── data/
│       ├── domain/
│       ├── presentation/
│       └── widgets/
└── main.dart
```

For small apps, keep the structure simpler if that improves maintainability.

General architecture rules:

- Separate UI, state, domain logic, and data access.
- Keep business logic out of `build()` methods.
- Use repository or service classes for API, database, storage, and platform
  integration logic.
- Keep models typed and explicit.
- Prefer immutable state objects where practical.
- Use `setState` only for ephemeral widget-local UI state such as expansion,
  focus, animation, or temporary input state.
- Put shared widgets in a common location only when they are genuinely reused.
- Keep files focused. Large widget files should be split when it improves
  readability.
- Prefer package imports for files under `lib/` when that is the project norm.
- Avoid `dynamic` and untyped public APIs.
- Use `const` constructors wherever they compile cleanly.

---

## 5. UI Guidelines

Build UI that is:

- Clean
- Responsive
- Accessible
- Consistent with the existing design system
- Easy to scan and use
- Appropriate for the product domain

Use the project theme:

- Prefer `ThemeData`, `ColorScheme`, `TextTheme`, and shared design tokens.
- Do not scatter hardcoded colors, text styles, spacing, or custom theme logic
  through feature widgets.
- Use reusable design constants or theme extensions when repeated values are
  meaningful.

For forms and user flows:

- Validate user input.
- Show loading states for async work.
- Show empty states when there is no data.
- Show error states when work fails.
- Avoid hidden behavior and confusing navigation.
- Keep destructive actions explicit and reversible where practical.

Accessibility:

- Use semantic labels for icon-only controls.
- Keep tap targets large enough for touch.
- Preserve keyboard navigation where relevant.
- Do not rely on color alone to communicate state.
- Make text scalable and avoid layouts that break at larger font sizes.

---

## 6. Responsive Layout Contract

One codebase should adapt across supported screen sizes.

Recommended form factors:

```dart
enum FormFactor { compact, medium, expanded }

// Suggested Material-style width classes:
// compact  < 600
// medium   600-839
// expanded >= 840
```

Rules:

- Branch on available width for layout, not on operating system.
- Use platform checks only for platform capabilities, not for ordinary layout.
- Keep layout state outside layout-specific widgets so resizing or rotation does
  not reset important user data.
- For medium widths, default to the compact layout unless the screen clearly
  benefits from an expanded presentation.
- Centralize form-factor logic in one helper, extension, or layout utility.
- Avoid raw width checks scattered through feature widgets.

Navigation:

- Compact screens usually use bottom navigation or simple app bars.
- Expanded screens may use a navigation rail, sidebar, split view, or wider
  content layout.
- A screen should not render its own global navigation if the app shell already
  owns navigation.

Modals:

- Prefer bottom sheets on compact screens.
- Prefer dialogs or side panels on expanded screens.
- Centralize adaptive modal behavior in a shared helper when the pattern repeats.

Large screens:

- Do not stretch narrow list content edge-to-edge across desktop widths.
- Constrain readable content with a max width.
- Use additional space for useful context, preview panes, filters, or navigation
  when that genuinely improves the workflow.

Proof obligation:

- Any new or changed important screen should be checked at a phone-like size and
  a desktop/tablet-like size.
- Widget tests should cover both sizes when the layout has meaningful adaptive
  behavior.

---

## 7. State Management

Use the state management approach already established by the project.

If no approach exists yet:

- Prefer the simplest option that fits the app.
- For shared app state, Riverpod without code generation is a good default.
- For very small local state, `setState` is acceptable.

State rules:

- Keep shared state out of widgets.
- Keep async loading, error, and empty states explicit.
- Keep provider, bloc, cubit, notifier, or controller APIs small and named by
  user intent.
- Avoid exposing mutable collections directly.
- Test important business logic outside the widget tree when possible.

---

## 8. Data, Services, And Persistence

Keep data access separate from UI.

Prefer:

- Repository or service classes for data logic.
- Models for structured data.
- Explicit error handling.
- Clear boundaries between local cache, remote API, and UI state.
- Easy-to-test pure functions for business rules.

Avoid:

- Calling APIs, databases, storage, or platform channels directly from widgets
  unless the app is intentionally tiny.
- Silent error handling.
- Hardcoded endpoints or credentials.
- Mixing serialization, validation, networking, and presentation in one class.

Persistence rules:

- Keep schema changes deliberate.
- Add migrations when persistent models change.
- Do not delete or rename stored fields without considering existing users.
- Keep secure values in secure storage, never in plain preferences or source
  files.

---

## 9. Assets

When adding assets:

- Put files in the correct asset folder.
- Update `pubspec.yaml`.
- Use clear, consistent file names.
- Avoid large unnecessary files.
- Keep icons, images, fonts, audio, and animation files organized.
- Prefer a central asset path file or generated asset access if the project has
  one.
- Do not hardcode the same asset path in many widgets.

Recommended folders:

```txt
assets/
├── audio/
├── fonts/
├── icons/
├── images/
└── animations/
```

---

## 10. Localization

If localization is already enabled:

- Use the existing localization system.
- Do not hardcode new user-facing strings outside the localization flow.

If localization is not enabled:

- Keep user-facing strings easy to find.
- Avoid scattering repeated strings across many files.
- For production apps, structure text so localization can be added later without
  a major rewrite.

---

## 11. Testing Strategy

Add tests in proportion to risk and user impact.

Prefer:

- Unit tests for business logic, formatters, validators, services, and pure
  functions.
- Widget tests for important UI behavior, navigation decisions, forms, empty
  states, error states, and adaptive layout.
- Repository or service tests for data handling.
- Golden tests only when the project is set up for them and the UI is stable.

Recommended responsive test sizes:

| Name | Logical size | Simulates |
| --- | --- | --- |
| `phone` | `390 x 844` | compact mobile layout |
| `desktop` | `1440 x 900` | expanded desktop/tablet layout |

Before considering a task complete, try to run:

```bash
flutter analyze
flutter test
```

For UI changes, also run the app where practical:

```bash
flutter run -d chrome
```

Use another target when it is more relevant:

```bash
flutter run -d windows
flutter run -d macos
flutter run -d linux
flutter run -d <device_id>
```

If verification cannot be run, explain why.

---

## 12. Commands Cheatsheet

Common commands:

```bash
flutter pub get
flutter pub add <package>
flutter analyze
flutter test
flutter run -d chrome
flutter devices
flutter clean
```

Code generation, only if the project uses it:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Release commands should be run only when explicitly requested:

```bash
flutter build apk --release
flutter build appbundle --release
flutter build ios --release
flutter build web --release
```

---

## 13. Android Release Readiness

When preparing an Android release, check:

- App name
- Package name / application ID
- Version name and version code
- App icon
- Required permissions
- Signing configuration
- Release build command
- Privacy policy requirements
- Play Store listing text
- Screenshots
- Internal testing readiness

Never expose, print, rewrite, or commit private signing credentials unless the
user explicitly requests a credential-related change and understands the risk.

---

## 14. Code Review Checklist

Before finishing, check:

- [ ] The change is scoped to the task.
- [ ] The code follows the existing project style.
- [ ] The app compiles, or any compile blocker is explained.
- [ ] `flutter analyze` passes, or failures are explained.
- [ ] Relevant tests pass, or unrun tests are explained.
- [ ] Important new logic has tests.
- [ ] Important changed UI works at compact and expanded sizes.
- [ ] Errors, loading states, and empty states are handled.
- [ ] Names are clear and types are explicit.
- [ ] Unused imports and dead code are removed.
- [ ] No secrets, credentials, signing files, or production configs were changed
      accidentally.
- [ ] No unrelated refactors were included.
- [ ] Dependencies were not added unnecessarily.

---

## 15. Multi-Agent Workflow


Recommended roles:

| Role | Responsibility |
| --- | --- |
| Orchestrator | Owns the task, keeps scope clear, decides the next step, and integrates results. |
| Explorer | Reads the codebase and reports what exists. Does not edit files. |
| Planner | Designs the implementation approach. Does not edit files. |
| Implementer | Makes the planned changes and runs verification. |
| Reviewer | Reviews the diff for bugs, regressions, conventions, and missing tests. |
| Tester | Adds or improves focused tests and runs them. |
| Doc Keeper | Updates project docs when behavior, setup, or architecture changes. |

Standard lifecycle for large changes:

```txt
Explorer -> Planner -> Implementer -> Reviewer -> Tester -> Doc Keeper
```

Parallelism rules:

- Parallelize independent read-only exploration.
- Parallelize implementation only when file sets are disjoint and there are no
  dependency ordering issues.
- Do not run reviewer and implementer in parallel.
- Do not run two implementers on the same file.
- When in doubt, serialize the work.

Agent prompt rules:

- Make each subagent prompt self-contained.
- Include relevant files, constraints, acceptance criteria, and verification
  commands.
- Tell read-only agents not to edit files.
- Tell implementers exactly which files or areas they may touch when the scope
  must stay tight.
- Require `flutter analyze` and relevant tests before implementation is reported
  complete.

---

## 16. Autonomous and loops

Work autonomously and in loops to implement, review, test, fix, and verify until the task is complete.

---

## 17. Project specific note

- Use flutter commands from powershell
- run and test on windows as primary target
- 