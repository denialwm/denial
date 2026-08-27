part of 'shell_controller.dart';

bool _sameWindowSnapshots(List<DenialWindow> a, List<DenialWindow> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

enum _GestureAxis { undecided, horizontal, vertical }
