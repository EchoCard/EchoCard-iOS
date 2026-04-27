# CallMate iOS Project Structure

## Top-level directories

- `App/`: app entry and root navigation.
- `Core/`: cross-feature infrastructure and system integration.
- `Features/`: business-facing screens and feature-specific logic.
- `Data/`: domain models and persistent stores.
- `Shared/`: reusable UI and shared helpers.
- `Assets.xcassets`, `en.lproj`, `zh-Hans.lproj`: app resources and localization.
- `ThirdParty/`: vendored native or external source code.

## Placement rules

1. New feature code goes under `Features/<FeatureName>/`.
2. Reusable services (network/audio/system) go under `Core/`.
3. Models used by multiple features go under `Data/Models/`.
4. Generic stores/state containers go under `Data/Stores/`.
5. Reusable UI components/theme helpers go under `Shared/UI/`.
6. Keep build-path-sensitive files stable unless build settings are updated:
   - `CallMate-Bridging-Header.h`
   - `ThirdParty/libsbc/include` (header search path)

## Migration strategy

- For old code, migrate by touch: move files when you modify a feature.
- Keep each move focused and build after changes to reduce regression risk.
