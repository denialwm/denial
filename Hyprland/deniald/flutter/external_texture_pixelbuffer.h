// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_PIXELBUFFER_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_PIXELBUFFER_H_

#include "flutter/external_texture.h"

namespace flutter {

// An abstraction of a pixel-buffer based texture.
class ExternalTexturePixelBuffer : public ExternalTexture {
 public:
  ExternalTexturePixelBuffer(
      ExternalTexturePixelBufferCallback texture_callback,
      void* user_data,
      const GlProcs& gl_procs);

  ~ExternalTexturePixelBuffer() override;

  // |ExternalTexture|
  bool PopulateTexture(size_t width,
                       size_t height,
                       FlutterOpenGLTexture* opengl_texture) override;

 private:
  // Attempts to copy the pixel buffer returned by |texture_callback_| to
  // OpenGL.
  // The |width| and |height| will be set to the actual bounds of the copied
  // pixel buffer.
  // Returns true on success or false if the pixel buffer returned
  // by |texture_callback_| was invalid.
  bool CopyPixelBuffer(size_t& width, size_t& height);

  GLuint gl_texture_ = 0;
  const ExternalTexturePixelBufferCallback texture_callback_;
  void* const user_data_ = nullptr;
  const GlProcs& gl_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_PIXELBUFFER_H_
