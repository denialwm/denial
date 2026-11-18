/// Settings is a program of its own, `denial-settings`: the GPUI application
/// from denial-apps, which the `denial` package installs on the desktop and
/// the phones. The shell starts it and knows its windows by this name, its
/// desktop entry and Wayland application id.
const denialSettingsApplication = 'org.denialwm.Settings';

bool isDenialSettingsApplicationId(String appId) =>
    appId.trim().toLowerCase() == denialSettingsApplication.toLowerCase();
