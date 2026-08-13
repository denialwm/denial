import 'package:flutter/widgets.dart';

/// Applies laptop-shell focus semantics to editable controls in mobile mode.
///
/// Flutter's default mobile action deliberately keeps an [EditableText]
/// focused after a touchscreen tap outside its tap region. Denial uses that
/// same tap to dismiss its system keyboard, so retaining focus would let the
/// next shell gesture reopen the keyboard. Field-to-field taps remain inside
/// the shared [TextFieldTapRegion] group and therefore never invoke this
/// action.
class MobileTextInputPolicy extends StatelessWidget {
  const MobileTextInputPolicy({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        EditableTextTapOutsideIntent:
            CallbackAction<EditableTextTapOutsideIntent>(
              onInvoke: (intent) {
                intent.focusNode.unfocus();
                return null;
              },
            ),
      },
      child: child,
    );
  }
}
