#include "settings_application.h"

#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

extern char **environ;

namespace {

void InstallLegacyDenialEnvironmentAliases() {
  std::vector<std::pair<std::string, std::string>> aliases;
  for (char **entry = environ; entry != nullptr && *entry != nullptr; ++entry) {
    const std::string assignment(*entry);
    const size_t separator = assignment.find('=');
    if (separator == std::string::npos) {
      continue;
    }
    const std::string name = assignment.substr(0, separator);
    constexpr char kCanonicalPrefix[] = "DENIAL_";
    if (name.rfind(kCanonicalPrefix, 0) != 0) {
      continue;
    }
    aliases.emplace_back("DENIA_" + name.substr(sizeof(kCanonicalPrefix) - 1),
                         assignment.substr(separator + 1));
  }
  for (const auto &alias : aliases) {
    setenv(alias.first.c_str(), alias.second.c_str(), 1);
  }
}

} // namespace

int main(int argc, char **argv) {
  InstallLegacyDenialEnvironmentAliases();
  g_autoptr(SettingsApplication) app = settings_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
