// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_TEXTURE_REGISTRAR_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_TEXTURE_REGISTRAR_H_

#include <functional>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

#include "flutter/external_texture.h"

namespace flutter {

class DenialFlutterEngine;

// An object managing the registration of an external texture.
// Thread safety: All member methods are thread safe.
class DenialFlutterTextureRegistrar {
 public:
  explicit DenialFlutterTextureRegistrar(DenialFlutterEngine* engine,
                                         const GlProcs& gl_procs);

  int64_t RegisterEGLImageTexture(ExternalTextureEGLImageCallback callback,
                                  void* user_data);
  int64_t RegisterPixelBufferTexture(
      ExternalTexturePixelBufferCallback callback,
      void* user_data);

  // Attempts to unregister the texture identified by |texture_id|.
  void UnregisterTexture(int64_t texture_id,
                         std::function<void()> callback = nullptr);

  // Notifies the engine about a new frame being available.
  // Returns true on success.
  bool MarkTextureFrameAvailable(int64_t texture_id);

  // Queues a stable image identifier for retirement. The actual GPU object
  // release happens the next time the texture is populated on the raster
  // thread.
  bool RetireTextureFrame(int64_t texture_id, uint64_t stable_id);

  // Attempts to populate the given |texture| by copying the
  // contents of the texture identified by |texture_id|.
  // Returns true on success.
  bool PopulateTexture(int64_t texture_id,
                       size_t width,
                       size_t height,
                       FlutterOpenGLTexture* texture);

  // Populates the OpenGL function pointers in |gl_procs|.
  static void ResolveGlFunctions(GlProcs& gl_procs);

 private:
  DenialFlutterEngine* engine_ = nullptr;
  const GlProcs& gl_procs_;

  // All registered textures, keyed by their IDs.
  std::unordered_map<int64_t, std::unique_ptr<flutter::ExternalTexture>>
      textures_;
  std::unordered_map<int64_t, std::unordered_set<uint64_t>>
      pending_retirements_;
  std::mutex map_mutex_;

  int64_t EmplaceTexture(std::unique_ptr<ExternalTexture> texture);
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_TEXTURE_REGISTRAR_H_
