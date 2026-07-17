// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/text_input_model.h"

#include <algorithm>
#include <cstdint>
#include <string_view>

namespace flutter {

namespace {

// Returns true if |code_point| is a leading surrogate of a surrogate pair.
bool IsLeadingSurrogate(char32_t code_point) {
  return (code_point & 0xFFFFFC00) == 0xD800;
}
// Returns true if |code_point| is a trailing surrogate of a surrogate pair.
bool IsTrailingSurrogate(char32_t code_point) {
  return (code_point & 0xFFFFFC00) == 0xDC00;
}

constexpr char32_t kReplacementCharacter = 0xFFFD;

bool IsUtf8Continuation(uint8_t byte) {
  return (byte & 0xC0) == 0x80;
}

void AppendUtf16(char32_t code_point, std::u16string* output) {
  if (code_point <= 0xFFFF) {
    output->push_back(static_cast<char16_t>(code_point));
    return;
  }

  code_point -= 0x10000;
  output->push_back(static_cast<char16_t>(0xD800 + (code_point >> 10)));
  output->push_back(static_cast<char16_t>(0xDC00 + (code_point & 0x3FF)));
}

std::u16string Utf8ToUtf16(std::string_view input) {
  std::u16string output;
  output.reserve(input.size());

  for (size_t index = 0; index < input.size();) {
    const auto first = static_cast<uint8_t>(input[index]);
    if (first < 0x80) {
      output.push_back(static_cast<char16_t>(first));
      ++index;
      continue;
    }

    size_t length = 0;
    char32_t code_point = 0;
    char32_t minimum = 0;
    if (first >= 0xC2 && first <= 0xDF) {
      length = 2;
      code_point = first & 0x1F;
      minimum = 0x80;
    } else if (first >= 0xE0 && first <= 0xEF) {
      length = 3;
      code_point = first & 0x0F;
      minimum = 0x800;
    } else if (first >= 0xF0 && first <= 0xF4) {
      length = 4;
      code_point = first & 0x07;
      minimum = 0x10000;
    } else {
      AppendUtf16(kReplacementCharacter, &output);
      ++index;
      continue;
    }

    bool valid = index + length <= input.size();
    for (size_t offset = 1; valid && offset < length; ++offset) {
      const auto next = static_cast<uint8_t>(input[index + offset]);
      valid = IsUtf8Continuation(next);
      if (valid) {
        code_point = (code_point << 6) | (next & 0x3F);
      }
    }

    valid = valid && code_point >= minimum && code_point <= 0x10FFFF &&
            !IsLeadingSurrogate(code_point) && !IsTrailingSurrogate(code_point);
    if (!valid) {
      AppendUtf16(kReplacementCharacter, &output);
      ++index;
      continue;
    }

    AppendUtf16(code_point, &output);
    index += length;
  }

  return output;
}

void AppendUtf8(char32_t code_point, std::string* output) {
  if (code_point <= 0x7F) {
    output->push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7FF) {
    output->push_back(static_cast<char>(0xC0 | (code_point >> 6)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else if (code_point <= 0xFFFF) {
    output->push_back(static_cast<char>(0xE0 | (code_point >> 12)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  } else {
    output->push_back(static_cast<char>(0xF0 | (code_point >> 18)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 12) & 0x3F)));
    output->push_back(static_cast<char>(0x80 | ((code_point >> 6) & 0x3F)));
    output->push_back(static_cast<char>(0x80 | (code_point & 0x3F)));
  }
}

std::string Utf16ToUtf8(std::u16string_view input) {
  std::string output;
  output.reserve(input.size());

  for (size_t index = 0; index < input.size(); ++index) {
    char32_t code_point = input[index];
    if (IsLeadingSurrogate(code_point)) {
      if (index + 1 < input.size() && IsTrailingSurrogate(input[index + 1])) {
        code_point =
            0x10000 + ((code_point - 0xD800) << 10) + (input[++index] - 0xDC00);
      } else {
        code_point = kReplacementCharacter;
      }
    } else if (IsTrailingSurrogate(code_point)) {
      code_point = kReplacementCharacter;
    }
    AppendUtf8(code_point, &output);
  }

  return output;
}

}  // namespace

TextInputModel::TextInputModel() = default;

TextInputModel::~TextInputModel() = default;

void TextInputModel::SetText(const std::string& text) {
  text_ = Utf8ToUtf16(text);
  selection_ = TextRange(0);
  composing_range_ = TextRange(0);
}

bool TextInputModel::SetSelection(const TextRange& range) {
  if (composing_ && !range.collapsed()) {
    return false;
  }
  if (!editable_range().Contains(range)) {
    return false;
  }
  selection_ = range;
  return true;
}

bool TextInputModel::SetComposingRange(const TextRange& range,
                                       size_t cursor_offset) {
  if (!composing_ || !text_range().Contains(range)) {
    return false;
  }
  composing_range_ = range;
  selection_ = TextRange(range.start() + cursor_offset);
  return true;
}

void TextInputModel::BeginComposing() {
  composing_ = true;
  composing_range_ = TextRange(selection_.start());
}

void TextInputModel::UpdateComposingText(const std::u16string& text) {
  // Preserve selection if we get a no-op update to the composing region.
  if (text.length() == 0 && composing_range_.collapsed()) {
    return;
  }
  DeleteSelected();
  text_.replace(composing_range_.start(), composing_range_.length(), text);
  composing_range_.set_end(composing_range_.start() + text.length());
  selection_ = TextRange(composing_range_.end());
}

void TextInputModel::UpdateComposingText(const std::string& text) {
  UpdateComposingText(Utf8ToUtf16(text));
}

void TextInputModel::CommitComposing() {
  // Preserve selection if no composing text was entered.
  if (composing_range_.collapsed()) {
    return;
  }
  composing_range_ = TextRange(composing_range_.end());
  selection_ = composing_range_;
}

void TextInputModel::EndComposing() {
  composing_ = false;
  composing_range_ = TextRange(0);
}

bool TextInputModel::DeleteSelected() {
  if (selection_.collapsed()) {
    return false;
  }
  size_t start = selection_.start();
  text_.erase(start, selection_.length());
  selection_ = TextRange(start);
  if (composing_) {
    // This occurs only immediately after composing has begun with a selection.
    composing_range_ = selection_;
  }
  return true;
}

void TextInputModel::AddCodePoint(char32_t c) {
  if (c > 0x10FFFF || IsLeadingSurrogate(c) || IsTrailingSurrogate(c)) {
    c = kReplacementCharacter;
  }
  if (c <= 0xFFFF) {
    AddText(std::u16string({static_cast<char16_t>(c)}));
  } else {
    char32_t to_decompose = c - 0x10000;
    AddText(std::u16string({
        // High surrogate.
        static_cast<char16_t>((to_decompose >> 10) + 0xd800),
        // Low surrogate.
        static_cast<char16_t>((to_decompose % 0x400) + 0xdc00),
    }));
  }
}

void TextInputModel::AddText(const std::u16string& text) {
  DeleteSelected();
  if (composing_) {
    // Delete the current composing text, set the cursor to composing start.
    text_.erase(composing_range_.start(), composing_range_.length());
    selection_ = TextRange(composing_range_.start());
    composing_range_.set_end(composing_range_.start() + text.length());
  }
  size_t position = selection_.position();
  text_.insert(position, text);
  selection_ = TextRange(position + text.length());
}

void TextInputModel::AddText(const std::string& text) {
  AddText(Utf8ToUtf16(text));
}

bool TextInputModel::Backspace() {
  if (DeleteSelected()) {
    return true;
  }
  // There is no selection. Delete the preceding codepoint.
  size_t position = selection_.position();
  if (position != editable_range().start()) {
    int count = IsTrailingSurrogate(text_.at(position - 1)) ? 2 : 1;
    text_.erase(position - count, count);
    selection_ = TextRange(position - count);
    if (composing_) {
      composing_range_.set_end(composing_range_.end() - count);
    }
    return true;
  }
  return false;
}

bool TextInputModel::Delete() {
  if (DeleteSelected()) {
    return true;
  }
  // There is no selection. Delete the preceding codepoint.
  size_t position = selection_.position();
  if (position < editable_range().end()) {
    int count = IsLeadingSurrogate(text_.at(position)) ? 2 : 1;
    text_.erase(position, count);
    if (composing_) {
      composing_range_.set_end(composing_range_.end() - count);
    }
    return true;
  }
  return false;
}

bool TextInputModel::DeleteSurrounding(int offset_from_cursor, int count) {
  size_t max_pos = editable_range().end();
  size_t start = selection_.extent();
  if (offset_from_cursor < 0) {
    for (int i = 0; i < -offset_from_cursor; i++) {
      // If requested start is before the available text then reduce the
      // number of characters to delete.
      if (start == editable_range().start()) {
        count = i;
        break;
      }
      start -= IsTrailingSurrogate(text_.at(start - 1)) ? 2 : 1;
    }
  } else {
    for (int i = 0; i < offset_from_cursor && start != max_pos; i++) {
      start += IsLeadingSurrogate(text_.at(start)) ? 2 : 1;
    }
  }

  auto end = start;
  for (int i = 0; i < count && end != max_pos; i++) {
    end += IsLeadingSurrogate(text_.at(start)) ? 2 : 1;
  }

  if (start == end) {
    return false;
  }

  auto deleted_length = end - start;
  text_.erase(start, deleted_length);

  // Cursor moves only if deleted area is before it.
  selection_ = TextRange(offset_from_cursor <= 0 ? start : selection_.start());

  // Adjust composing range.
  if (composing_) {
    composing_range_.set_end(composing_range_.end() - deleted_length);
  }
  return true;
}

bool TextInputModel::MoveCursorToBeginning() {
  size_t min_pos = editable_range().start();
  if (selection_.collapsed() && selection_.position() == min_pos) {
    return false;
  }
  selection_ = TextRange(min_pos);
  return true;
}

bool TextInputModel::MoveCursorToEnd() {
  size_t max_pos = editable_range().end();
  if (selection_.collapsed() && selection_.position() == max_pos) {
    return false;
  }
  selection_ = TextRange(max_pos);
  return true;
}

bool TextInputModel::SelectToBeginning() {
  size_t min_pos = editable_range().start();
  if (selection_.collapsed() && selection_.position() == min_pos) {
    return false;
  }
  selection_ = TextRange(selection_.base(), min_pos);
  return true;
}

bool TextInputModel::SelectToEnd() {
  size_t max_pos = editable_range().end();
  if (selection_.collapsed() && selection_.position() == max_pos) {
    return false;
  }
  selection_ = TextRange(selection_.base(), max_pos);
  return true;
}

bool TextInputModel::MoveCursorForward() {
  // If there's a selection, move to the end of the selection.
  if (!selection_.collapsed()) {
    selection_ = TextRange(selection_.end());
    return true;
  }
  // Otherwise, move the cursor forward.
  size_t position = selection_.position();
  if (position != editable_range().end()) {
    int count = IsLeadingSurrogate(text_.at(position)) ? 2 : 1;
    selection_ = TextRange(position + count);
    return true;
  }
  return false;
}

bool TextInputModel::MoveCursorBack() {
  // If there's a selection, move to the beginning of the selection.
  if (!selection_.collapsed()) {
    selection_ = TextRange(selection_.start());
    return true;
  }
  // Otherwise, move the cursor backward.
  size_t position = selection_.position();
  if (position != editable_range().start()) {
    int count = IsTrailingSurrogate(text_.at(position - 1)) ? 2 : 1;
    selection_ = TextRange(position - count);
    return true;
  }
  return false;
}

std::string TextInputModel::GetText() const {
  return Utf16ToUtf8(text_);
}

int TextInputModel::GetCursorOffset() const {
  // Measure the length of the current text up to the selection extent.
  // There is probably a much more efficient way of doing this.
  auto leading_text = text_.substr(0, selection_.extent());
  return static_cast<int>(Utf16ToUtf8(leading_text).size());
}

}  // namespace flutter
