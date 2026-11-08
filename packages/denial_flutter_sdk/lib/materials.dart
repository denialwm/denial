/// Shared application materials. Adopt by semantic role; do not duplicate
/// backing colors, opacity calculations or backdrop filters in individual apps.
library;

export 'src/theme/application_material_policy.dart'
    show DenialMaterialBackdrop, DenialMaterialPolicy, DenialMaterialRole;
export 'src/theme/application_theme.dart'
    show
        DenialApplicationColors,
        DenialApplicationTheme,
        DenialApplicationThemeContext;
export 'src/widgets/application_material.dart'
    show
      DenialApplicationFrame,
      DenialContentPane,
      DenialFlatApplicationFrame,
      DenialMaterial;
export 'src/widgets/content_switcher.dart' show DenialContentSwitcher;
export 'src/widgets/surface_geometry.dart' show DenialSurfaceGeometry;
