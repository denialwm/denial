import '../models/desktop_app.dart';

class DesktopExecParser {
  const DesktopExecParser();

  List<String> parse(String exec, DesktopApp app) {
    final tokens = _split(exec);
    final argv = <String>[];

    for (final token in tokens) {
      final expanded = _expandToken(token, app);
      if (expanded.isNotEmpty) {
        argv.add(expanded);
      }
    }

    return argv;
  }

  List<String> _split(String exec) {
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quote = '';
    var escaped = false;

    for (var i = 0; i < exec.length; i += 1) {
      final char = exec[i];
      if (escaped) {
        buffer.write(char);
        escaped = false;
        continue;
      }

      if (char == r'\') {
        escaped = true;
        continue;
      }

      if (quote.isNotEmpty) {
        if (char == quote) {
          quote = '';
        } else {
          buffer.write(char);
        }
        continue;
      }

      if (char == '"' || char == "'") {
        quote = char;
        continue;
      }

      if (char.trim().isEmpty) {
        if (buffer.isNotEmpty) {
          tokens.add(buffer.toString());
          buffer.clear();
        }
        continue;
      }

      buffer.write(char);
    }

    if (escaped) {
      buffer.write(r'\');
    }
    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
    }

    return tokens;
  }

  String _expandToken(String token, DesktopApp app) {
    var result = token;
    result = result.replaceAll('%%', '\u0000');
    result = result.replaceAll('%c', app.name);
    result = result.replaceAll('%k', app.desktopPath);
    result = result.replaceAll('%i', '');
    result = result.replaceAll(RegExp(r'%[fFuUdDnNickvm]'), '');
    result = result.replaceAll('\u0000', '%');
    return result.trim();
  }
}
