/// Public framework API for building Denial shell features.
///
/// Import this library instead of files below `lib/src`. A custom shell only
/// needs to provide [DenialShellScene] widgets to [DenialShell]; compositor
/// lifecycle and platform plumbing stay inside the framework.
library;

export 'src/core/denial_shell.dart';
export 'src/core/denial_shell_bootstrap.dart';
export 'src/core/shell_scene.dart';
export 'src/core/shell_runtime_bindings.dart'
    show DenialPairingSurfaceBuilder, DenialShellEffect;
export 'src/core/shell_secure_stage.dart' show UnlockTransitionHost;
export 'src/core/shell_window_providers.dart';
export 'src/core/shell_windows.dart';
export 'src/input/input_layout.dart';
export 'src/config/startup_environment.dart' show StartupEnvironment;
export 'src/launcher/controllers/application_recents_controller.dart';
export 'src/launcher/controllers/home_grid_controller.dart';
export 'src/launcher/models/desktop_app.dart';
export 'src/launcher/models/home_grid_item.dart';
export 'src/local_apps/local_flutter_application.dart';
export 'src/local_apps/local_flutter_window_host.dart';
export 'src/models/app_launch_request.dart';
export 'src/models/denial_drag_icon.dart';
export 'src/models/denial_window.dart';
export 'src/models/denial_window_snapshot.dart';
export 'src/models/display_layout.dart';
export 'src/models/shell_popup_placement.dart';
export 'src/settings/settings_controller.dart'
    show shellSettingsProvider, ShellSettingsController;
export 'src/settings/shell_settings.dart';
export 'src/state/display_layout.dart';
export 'src/state/shell_controller.dart'
    show shellControllerProvider, ShellController;
export 'src/state/shell_profile.dart';
export 'src/state/shell_state.dart';
export 'src/theme/backdrop_blur_level.dart';
export 'src/theme/cursor_themes.dart';
export 'src/theme/motion.dart';
export 'src/theme/shell_color_scheme.dart';
export 'src/theme/shell_text_theme.dart';
export 'src/theme/shell_theme.dart';
export 'src/theme/tokens.dart';
export 'src/widgets/app_icon.dart';
export 'src/widgets/launch_transition_layer.dart';
export 'src/widgets/overview/overview_layer.dart';
export 'src/widgets/shell_backdrop_blur.dart';
export 'src/widgets/shell_surface_host.dart';
export 'src/widgets/shell_wallpaper.dart';
export 'src/widgets/window_content_rect.dart';
export 'src/widgets/window_surface_tree.dart';
