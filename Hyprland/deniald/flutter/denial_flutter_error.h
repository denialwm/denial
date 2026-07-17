// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ERROR_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ERROR_H_

#include <iostream>
#include <sstream>

namespace flutter {

#define DENIAL_FLUTTER_ERROR DenialFlutterError(__func__, __LINE__).stream()

class DenialFlutterError {
 public:
  DenialFlutterError(const char* function, int line) {
    stream_ << "[ERROR][" << function << "(" << line << ")] ";
  }

  ~DenialFlutterError() { std::cerr << stream_.str() << '\n'; }

  std::ostream& stream() { return stream_; }

 private:
  std::ostringstream stream_;
};

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_EMBEDDED_DENIAL_FLUTTER_ERROR_H_
