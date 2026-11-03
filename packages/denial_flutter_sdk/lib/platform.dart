/// Shared platform bridge, typed operation results and native events.
/// Protocol codecs and channel constants are available from wire.dart.
/// Obtain the existing bridge through denialBridgeProvider in state.dart.
library;

export 'src/platform/bridge/input_deck_client.dart' show InputDeckSnapshot;

export 'src/platform/authentication_protocol.dart'
    show AuthenticationPromptStyle;
export 'src/platform/denial_bridge.dart'
    show DenialBridge, DenialOutputControlException;
export 'src/platform/denial_bridge_models.dart'
    show
        DenialAudioDevice,
        DenialAudioState,
        DenialAudioStream,
        DenialBrightnessState,
        DenialSettingsDocument,
        DenialShellAction,
        DenialShellActionEvent,
        DenialSoftwareDimmingState,
        DenialTextInputState,
        DenialTextPrediction;
