#ifndef DENIAL_SETTINGS_APPLICATION_H_
#define DENIAL_SETTINGS_APPLICATION_H_

#include <gtk/gtk.h>

G_DECLARE_FINAL_TYPE(SettingsApplication,
                     settings_application,
                     DENIAL,
                     SETTINGS_APPLICATION,
                     GtkApplication)

SettingsApplication* settings_application_new();

#endif  // DENIAL_SETTINGS_APPLICATION_H_
