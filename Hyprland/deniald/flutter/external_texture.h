// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_H_

#include <cstddef>
#include <cstdint>

#include "flutter/embedder.h"

#ifdef USE_GLES3
#include <GLES3/gl32.h>
#else
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#endif

namespace flutter {

using glGenTexturesProc = void (*)(GLsizei n, GLuint* textures);
using glDeleteTexturesProc = void (*)(GLsizei n, const GLuint* textures);
using glBindTextureProc = void (*)(GLenum target, GLuint texture);
using glTexParameteriProc = void (*)(GLenum target, GLenum pname, GLint param);
using glTexImage2DProc = void (*)(GLenum target,
                                  GLint level,
                                  GLint internalformat,
                                  GLsizei width,
                                  GLsizei height,
                                  GLint border,
                                  GLenum format,
                                  GLenum type,
                                  const void* data);
using glEGLImageTargetTexture2DOESProc = void (*)(GLenum target,
                                                  GLeglImageOES image);

// A struct containing pointers to resolved gl* functions.
struct GlProcs {
  glGenTexturesProc glGenTextures = nullptr;
  glDeleteTexturesProc glDeleteTextures = nullptr;
  glBindTextureProc glBindTexture = nullptr;
  glTexParameteriProc glTexParameteri = nullptr;
  glTexImage2DProc glTexImage2D = nullptr;
  glEGLImageTargetTexture2DOESProc glEGLImageTargetTexture2DOES = nullptr;
  bool valid = false;
};

struct ExternalTexturePixelBufferFrame {
  const uint8_t* buffer;
  size_t width;
  size_t height;
  void (*release_callback)(void* release_context);
  void* release_context;
};

using ExternalTexturePixelBufferCallback =
    const ExternalTexturePixelBufferFrame* (*)(size_t width,
                                               size_t height,
                                               void* user_data);

struct ExternalTextureEGLImageFrame {
  const void* egl_image;
  uint64_t stable_id;
  size_t width;
  size_t height;
  void (*release_callback)(void* release_context);
  void* release_context;
};

using ExternalTextureEGLImageCallback =
    const ExternalTextureEGLImageFrame* (*)(size_t width,
                                            size_t height,
                                            void* egl_display,
                                            void* egl_context,
                                            void* user_data);

// Abstract external texture.
class ExternalTexture {
 public:
  virtual ~ExternalTexture() = default;

  // Returns the unique id of this texture.
  int64_t texture_id() const { return reinterpret_cast<int64_t>(this); }

  // Attempts to populate the specified |opengl_texture| with texture details
  // such as the name, width, height and the pixel format.
  // Returns true on success.
  virtual bool PopulateTexture(size_t width,
                               size_t height,
                               FlutterOpenGLTexture* opengl_texture) = 0;

  // Retires an embedder-provided stable image identifier. Implementations
  // that cache GPU bindings may release the corresponding object here. This
  // method is invoked on the raster thread.
  virtual void RetireFrame(uint64_t stable_id) { (void)stable_id; }
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_EXTERNAL_TEXTURE_H_
