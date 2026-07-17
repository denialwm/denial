// Copyright 2026.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_RENDER_DELEGATE_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_RENDER_DELEGATE_H_

#include <cstddef>
#include <cstdint>

#include "flutter/embedder.h"

namespace flutter {

struct PhysicalWindowBounds {
  size_t width;
  size_t height;
};

class DenialRenderDelegate {
 public:
  virtual ~DenialRenderDelegate() = default;

  virtual bool GLContextMakeCurrent() const = 0;
  virtual bool GLContextClearCurrent() const = 0;
  virtual bool GLContextPresentWithInfo(
      const FlutterPresentInfo* info) const = 0;
  virtual void PopulateExistingDamage(intptr_t fbo_id,
                                      FlutterDamage* existing_damage) const = 0;
  virtual uint32_t GLContextFBO() const = 0;
  virtual bool ResourceContextMakeCurrent() const = 0;
  virtual void* GlProcResolver(const char* name) const = 0;

  virtual bool OnScreenSurfaceResize(size_t width_px, size_t height_px) = 0;
  virtual PhysicalWindowBounds GetPhysicalWindowBounds() const = 0;
  virtual double GetDpiScale() const = 0;
  virtual int32_t GetFrameRate() const = 0;
  virtual uint16_t GetSurfaceTransform() const = 0;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_DENIAL_RENDER_DELEGATE_H_
