// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/external_texture_egl_image.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <algorithm>

namespace flutter {

namespace {

constexpr size_t kMaxCachedBindings = 8;

}  // namespace

ExternalTextureEGLImage::ExternalTextureEGLImage(
    ExternalTextureEGLImageCallback texture_callback,
    void* user_data,
    const GlProcs& gl_procs)
    : texture_callback_(texture_callback),
      user_data_(user_data),
      gl_(gl_procs) {}

ExternalTextureEGLImage::~ExternalTextureEGLImage() {
  for (const auto& [image_key, binding] : bindings_by_image_) {
    (void)image_key;
    if (binding.texture != 0) {
      gl_.glDeleteTextures(1, &binding.texture);
    }
  }
}

void ExternalTextureEGLImage::RetireFrame(uint64_t stable_id) {
  if (stable_id == 0) {
    return;
  }

  const auto binding = bindings_by_image_.find(stable_id);
  if (binding == bindings_by_image_.end()) {
    return;
  }

  if (binding->second.texture != 0) {
    gl_.glDeleteTextures(1, &binding->second.texture);
  }
  if (current_image_key_ == stable_id) {
    current_image_key_ = 0;
    current_texture_ = 0;
  }
  bindings_by_image_.erase(binding);
}

bool ExternalTextureEGLImage::PopulateTexture(
    size_t width,
    size_t height,
    FlutterOpenGLTexture* opengl_texture) {
  if (!GetEGLImage(width, height, eglGetCurrentDisplay(),
                   eglGetCurrentContext())) {
    return false;
  }

  // Populate the texture object used by the engine.
  opengl_texture->target = GL_TEXTURE_2D;
  opengl_texture->name = current_texture_;
#ifdef USE_GLES3
  opengl_texture->format = GL_RGBA8;
#else
  opengl_texture->format = GL_RGBA8_OES;
#endif
  opengl_texture->destruction_callback = nullptr;
  opengl_texture->user_data = nullptr;
  opengl_texture->width = width;
  opengl_texture->height = height;

  return true;
}

bool ExternalTextureEGLImage::GetEGLImage(size_t& width,
                                          size_t& height,
                                          void* egl_display,
                                          void* egl_context) {
  const ExternalTextureEGLImageFrame* egl_image =
      texture_callback_(width, height, egl_display, egl_context, user_data_);
  if (!egl_image || !egl_image->egl_image) {
    return false;
  }
  width = egl_image->width;
  height = egl_image->height;

  const auto image_key = egl_image->stable_id != 0
                             ? egl_image->stable_id
                             : reinterpret_cast<uint64_t>(egl_image->egl_image);

  auto binding = bindings_by_image_.find(image_key);
  if (binding == bindings_by_image_.end()) {
    if (bindings_by_image_.size() >= kMaxCachedBindings) {
      auto eviction = bindings_by_image_.end();
      for (auto it = bindings_by_image_.begin(); it != bindings_by_image_.end();
           ++it) {
        if (it->first == current_image_key_) {
          continue;
        }
        if (eviction == bindings_by_image_.end() ||
            it->second.last_used_epoch < eviction->second.last_used_epoch) {
          eviction = it;
        }
      }

      // A cache at the limit normally has several swapchain entries. Keep a
      // conservative fallback for a malformed stream that somehow leaves only
      // the current entry eligible.
      if (eviction == bindings_by_image_.end()) {
        eviction = std::min_element(
            bindings_by_image_.begin(), bindings_by_image_.end(),
            [](const auto& lhs, const auto& rhs) {
              return lhs.second.last_used_epoch < rhs.second.last_used_epoch;
            });
      }
      if (eviction != bindings_by_image_.end()) {
        if (eviction->second.texture != 0) {
          gl_.glDeleteTextures(1, &eviction->second.texture);
        }
        if (eviction->first == current_image_key_) {
          current_image_key_ = 0;
          current_texture_ = 0;
        }
        bindings_by_image_.erase(eviction);
      }
    }

    GLuint gl_texture = 0;
    gl_.glGenTextures(1, &gl_texture);

    gl_.glBindTexture(GL_TEXTURE_2D, gl_texture);
    gl_.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl_.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl_.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl_.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    gl_.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D,
                                     (EGLImageKHR)egl_image->egl_image);
    binding = bindings_by_image_
                  .emplace(image_key, CachedGLBinding{gl_texture, ++use_epoch_})
                  .first;
  } else {
    binding->second.last_used_epoch = ++use_epoch_;
    gl_.glBindTexture(GL_TEXTURE_2D, binding->second.texture);
  }

  current_texture_ = binding->second.texture;
  current_image_key_ = image_key;

  if (egl_image->release_callback) {
    egl_image->release_callback(egl_image->release_context);
  }
  return true;
}

}  // namespace flutter
