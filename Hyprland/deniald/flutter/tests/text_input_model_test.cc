// Copyright 2026 The Denial Authors.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <iostream>
#include <string>

#include "flutter/text_input_model.h"

namespace {

bool Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

}  // namespace

int main() {
  flutter::TextInputModel model;

  const std::string sample = "ASCII \xC3\xA9 \xE4\xB8\xAD \xF0\x9F\x98\x80";
  model.SetText(sample);
  if (!Expect(model.GetText() == sample, "valid UTF-8 text changed") ||
      !Expect(model.SetSelection(flutter::TextRange(model.text_range().end())),
              "valid cursor selection was rejected") ||
      !Expect(model.GetCursorOffset() == static_cast<int>(sample.size()),
              "cursor offset does not match the UTF-8 byte length")) {
    return 1;
  }

  model.SetText("\xF0\x28\x8C\x28");
  if (!Expect(model.GetText() == "\xEF\xBF\xBD\x28\xEF\xBF\xBD\x28",
              "invalid UTF-8 was not normalized")) {
    return 1;
  }

  model.SetText("");
  model.AddCodePoint(0x1F600);
  model.AddCodePoint(0x110000);
  if (!Expect(model.GetText() == "\xF0\x9F\x98\x80\xEF\xBF\xBD",
              "code-point insertion produced unexpected UTF-8")) {
    return 1;
  }

  return 0;
}
