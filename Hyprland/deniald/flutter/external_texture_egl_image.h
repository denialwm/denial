// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_EGL_IMAGE_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_EGL_IMAGE_H_

#include <cstdint>
#include <unordered_map>

#include "flutter/external_texture.h"

namespace flutter {

// An abstraction of an EGL Image based texture.
class ExternalTextureEGLImage : public ExternalTexture {
 public:
  ExternalTextureEGLImage(ExternalTextureEGLImageCallback texture_callback,
                          void* user_data,
                          const GlProcs& gl_procs);

  ~ExternalTextureEGLImage() override;

  // |ExternalTexture|
  bool PopulateTexture(size_t width,
                       size_t height,
                       FlutterOpenGLTexture* opengl_texture) override;

  // |ExternalTexture|
  void RetireFrame(uint64_t stable_id) override;

 private:
  struct CachedGLBinding {
    GLuint texture = 0;
    uint64_t last_used_epoch = 0;
  };

  // Attempts to get the EGLImage returned by |texture_callback_| to
  // OpenGL.
  // The |width| and |height| will be set to the actual bounds of the EGLImage
  // Returns true on success or false if the EGLImage returned
  // by |texture_callback_| was invalid.
  bool GetEGLImage(size_t& width,
                   size_t& height,
                   void* egl_display,
                   void* egl_context);

  GLuint current_texture_ = 0;
  uint64_t current_image_key_ = 0;
  uint64_t use_epoch_ = 0;
  std::unordered_map<uint64_t, CachedGLBinding> bindings_by_image_;
  const ExternalTextureEGLImageCallback texture_callback_;
  void* const user_data_ = nullptr;
  const GlProcs& gl_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_EGL_IMAGE_H_
