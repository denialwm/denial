#pragma once

#include "BridgeAPI.hpp"

#include <hyprutils/math/Vector2D.hpp>

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

class CWLSurfaceResource;

namespace Denial {

    struct SInputRect {
        double x = 0.0;
        double y = 0.0;
        double w = 0.0;
        double h = 0.0;

        bool   contains(const Vector2D& point) const {
            return w > 0.0 && h > 0.0 && point.x >= x && point.y >= y && point.x < x + w && point.y < y + h;
        }

        Vector2D mapTo(const SInputRect& source, const Vector2D& point) const {
            if (w <= 0.0 || h <= 0.0)
                return {source.x, source.y};

            const double sx = source.w / w;
            const double sy = source.h / h;
            return {source.x + ((point.x - x) * sx), source.y + ((point.y - y) * sy)};
        }
    };

    struct SInputWindowRecord {
        TSurfaceId surfaceId = 0;
        TSurfaceId objectId  = 0;
        TWindowId  windowId  = 0;
        SInputRect rect;
        SInputRect sourceRect;
        int32_t    z              = 0;
        bool       visible        = true;
        bool       hitTest        = true;
        bool       geometryLocked = false;
    };

    struct SInputShellRegion {
        SInputRect rect;
    };

    struct SInputLayoutSnapshot {
        uint64_t                        epoch              = 0;
        bool                            keyboardCapture    = false;
        bool                            exclusiveShellMode = false;
        std::vector<SInputShellRegion>  shellRegions;
        std::vector<SInputWindowRecord> windows;
    };

    enum class EInputHitKind : uint8_t {
        None,
        FlutterShell,
        ClientWindow,
    };

    enum class EFlutterPointerButton : uint64_t {
        Primary   = 1ULL << 0,
        Secondary = 1ULL << 1,
        Middle    = 1ULL << 2,
        Back      = 1ULL << 3,
        Forward   = 1ULL << 4,
    };

    struct SFlutterKeyboardEvent {
        uint32_t timeMs  = 0;
        uint32_t keycode = 0;
        bool     pressed = false;
        bool     repeat  = false;
    };

    struct SFlutterKeyboardModifiers {
        uint32_t depressed = 0;
        uint32_t latched   = 0;
        uint32_t locked    = 0;
        uint32_t group     = 0;
    };

    enum class EClientWindowPlacementPhase : uint8_t {
        Begin,
        Update,
        End,
    };

    enum class EClientWindowPlacementChange : uint8_t {
        Move,
        Resize,
    };

    enum class EInputHitMissReason : uint8_t {
        None,
        InputLayoutUnavailable,
        WindowRegionsUnavailable,
        NoRegionAtPoint,
        CandidateNotVisible,
        CandidateHitTestDisabled,
        ExternalTextureUnavailable,
        ExternalTextureSurfaceExpired,
        ExternalTextureWindowExpired,
    };

    struct SInputHit {
        EInputHitKind          kind       = EInputHitKind::None;
        EInputHitMissReason    missReason = EInputHitMissReason::None;
        TSurfaceId             objectId   = 0;
        TSurfaceId             surfaceId  = 0;
        TWindowId              windowId   = 0;
        uint32_t               inputFlags = 0;
        PHLWINDOW              window;
        SP<CWLSurfaceResource> surface;
        SInputRect             rect;
        SInputRect             sourceRect;
        Vector2D               local;
    };

    class IInputRouter {
      public:
        virtual ~IInputRouter() = default;

        virtual bool hitTest(MONITORID monitorId, const Vector2D& outputLogical, SInputHit& hit)                                           = 0;
        virtual bool sendFlutterTouchDown(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical)            = 0;
        virtual bool sendFlutterTouchMotion(uint32_t timeMs, int32_t touchId, MONITORID monitorId, const Vector2D& outputLogical)          = 0;
        virtual bool sendFlutterTouchUp(uint32_t timeMs, int32_t touchId)                                                                  = 0;
        virtual bool sendFlutterTouchCancel()                                                                                              = 0;
        virtual bool sendFlutterPointerMove(MONITORID monitorId, const Vector2D& outputLogical)                                            = 0;
        virtual bool sendFlutterPointerDown(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button)              = 0;
        virtual bool sendFlutterPointerUp(MONITORID monitorId, const Vector2D& outputLogical, EFlutterPointerButton button)                = 0;
        virtual bool sendFlutterPointerLeave()                                                                                             = 0;
        virtual bool sendFlutterPointerScroll(MONITORID monitorId, const Vector2D& outputLogical, const Vector2D& delta)                   = 0;
        virtual bool flutterKeyboardCapture() const                                                                                        = 0;
        virtual bool sendFlutterKeyboardKey(const SFlutterKeyboardEvent& event)                                                            = 0;
        virtual bool sendFlutterKeyboardModifiers(const SFlutterKeyboardModifiers& modifiers)                                              = 0;
        virtual bool sendFlutterKeyboardKeymap(std::string_view keymap)                                                                    = 0;
        virtual void notifyClientWindowActivated(TWindowId windowId)                                                                       = 0;
        virtual void notifyClientWindowPlacement(PHLWINDOW window, EClientWindowPlacementPhase phase, EClientWindowPlacementChange change) = 0;
        virtual void notifyCursorShape(const std::string& shape)                                                                           = 0;
        virtual void notifyCursorPosition(MONITORID monitorId, const Vector2D& outputLogical)                                              = 0;
        virtual void notifyDragIconSurface(SP<CWLSurfaceResource> surface)                                                                 = 0;
        virtual bool secureSessionLocked() const                                                                                           = 0;
        virtual bool shellExclusiveMode() const                                                                                            = 0;
        virtual bool windowGeometryLocked(TWindowId windowId)                                                                              = 0;
        virtual bool dispatchShortcutAction(const std::string& action, std::string& error)                                                 = 0;
    };

    void          setInputRouter(IInputRouter* router);
    IInputRouter* inputRouter();

} // namespace Denial
