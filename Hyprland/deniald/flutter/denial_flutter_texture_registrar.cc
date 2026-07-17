// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/denial_flutter_texture_registrar.h"

#include <EGL/egl.h>

#include <mutex>

#include "flutter/denial_flutter_engine.h"
#include "flutter/external_texture_egl_image.h"
#include "flutter/external_texture_pixelbuffer.h"

namespace {
constexpr int64_t kInvalidTexture = -1;
}

namespace flutter {

DenialFlutterTextureRegistrar::DenialFlutterTextureRegistrar(
    DenialFlutterEngine* engine,
    const GlProcs& gl_procs)
    : engine_(engine), gl_procs_(gl_procs) {}

int64_t DenialFlutterTextureRegistrar::RegisterEGLImageTexture(
    ExternalTextureEGLImageCallback callback,
    void* user_data) {
  if (!gl_procs_.valid || !callback) {
    return kInvalidTexture;
  }

  return EmplaceTexture(std::make_unique<ExternalTextureEGLImage>(
      callback, user_data, gl_procs_));
}

int64_t DenialFlutterTextureRegistrar::RegisterPixelBufferTexture(
    ExternalTexturePixelBufferCallback callback,
    void* user_data) {
  if (!gl_procs_.valid || !callback) {
    return kInvalidTexture;
  }

  return EmplaceTexture(std::make_unique<ExternalTexturePixelBuffer>(
      callback, user_data, gl_procs_));
}

int64_t DenialFlutterTextureRegistrar::EmplaceTexture(
    std::unique_ptr<ExternalTexture> texture) {
  if (!engine_->RunsPlatformTasksOnCurrentThread()) {
    return kInvalidTexture;
  }

  int64_t texture_id = texture->texture_id();
  {
    std::lock_guard<std::mutex> lock(map_mutex_);
    textures_[texture_id] = std::move(texture);
  }

  if (!engine_->RegisterExternalTexture(texture_id)) {
    std::lock_guard<std::mutex> lock(map_mutex_);
    textures_.erase(texture_id);
    return kInvalidTexture;
  }

  return texture_id;
}

void DenialFlutterTextureRegistrar::UnregisterTexture(
    int64_t texture_id,
    std::function<void()> callback) {
  if (!engine_->RunsPlatformTasksOnCurrentThread()) {
    if (callback) {
      callback();
    }
    return;
  }
  engine_->UnregisterExternalTexture(texture_id);

  bool posted = engine_->PostRasterThreadTask([this, texture_id, callback]() {
    {
      std::lock_guard<std::mutex> lock(map_mutex_);
      auto it = textures_.find(texture_id);
      if (it != textures_.end()) {
        pending_retirements_.erase(texture_id);
        textures_.erase(it);
      }
    }
    if (callback) {
      callback();
    }
  });

  if (!posted && callback) {
    callback();
  }
}

bool DenialFlutterTextureRegistrar::MarkTextureFrameAvailable(
    int64_t texture_id) {
  return engine_->RunsPlatformTasksOnCurrentThread() &&
         engine_->MarkExternalTextureFrameAvailable(texture_id);
}

bool DenialFlutterTextureRegistrar::RetireTextureFrame(int64_t texture_id,
                                                       uint64_t stable_id) {
  if (stable_id == 0) {
    return false;
  }

  std::lock_guard<std::mutex> lock(map_mutex_);
  const auto texture = textures_.find(texture_id);
  if (texture == textures_.end() || !texture->second) {
    return false;
  }

  pending_retirements_[texture_id].insert(stable_id);
  return true;
}

bool DenialFlutterTextureRegistrar::PopulateTexture(
    int64_t texture_id,
    size_t width,
    size_t height,
    FlutterOpenGLTexture* opengl_texture) {
  flutter::ExternalTexture* texture;
  std::unordered_set<uint64_t> retirements;
  {
    std::lock_guard<std::mutex> lock(map_mutex_);
    auto it = textures_.find(texture_id);
    if (it == textures_.end()) {
      return false;
    }
    texture = it->second.get();

    auto pending = pending_retirements_.find(texture_id);
    if (pending != pending_retirements_.end()) {
      retirements = std::move(pending->second);
      pending_retirements_.erase(pending);
    }
  }

  // PopulateTexture runs on Flutter's raster thread with the render context
  // current. Retiring here avoids allocating and posting one cross-thread
  // closure for every destroyed compositor buffer.
  for (const uint64_t stable_id : retirements) {
    texture->RetireFrame(stable_id);
  }

  return texture->PopulateTexture(width, height, opengl_texture);
}

void DenialFlutterTextureRegistrar::ResolveGlFunctions(GlProcs& procs) {
  procs.glGenTextures =
      reinterpret_cast<glGenTexturesProc>(eglGetProcAddress("glGenTextures"));
  procs.glDeleteTextures = reinterpret_cast<glDeleteTexturesProc>(
      eglGetProcAddress("glDeleteTextures"));
  procs.glBindTexture =
      reinterpret_cast<glBindTextureProc>(eglGetProcAddress("glBindTexture"));
  procs.glTexParameteri = reinterpret_cast<glTexParameteriProc>(
      eglGetProcAddress("glTexParameteri"));
  procs.glTexImage2D =
      reinterpret_cast<glTexImage2DProc>(eglGetProcAddress("glTexImage2D"));
  procs.glEGLImageTargetTexture2DOES =
      reinterpret_cast<glEGLImageTargetTexture2DOESProc>(
          eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  procs.valid = procs.glGenTextures && procs.glDeleteTextures &&
                procs.glBindTexture && procs.glTexParameteri &&
                procs.glTexImage2D && procs.glEGLImageTargetTexture2DOES;
}

}  // namespace flutter
