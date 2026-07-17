class DesktopApp {
  const DesktopApp({
    required this.id,
    required this.name,
    required this.exec,
    required this.desktopPath,
    required this.categories,
    this.icon,
    this.iconPath,
    this.startupWmClass,
  });

  final String id;
  final String name;
  final String exec;
  final String desktopPath;
  final List<String> categories;
  final String? icon;
  final String? iconPath;
  final String? startupWmClass;
}
