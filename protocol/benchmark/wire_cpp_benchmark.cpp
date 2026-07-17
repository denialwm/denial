#include "../../Hyprland/deniald/Wire.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace {
using namespace Denial;

volatile uint64_t sink = 0;

struct JsonRect {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

struct JsonInputWindow {
  uint64_t objectId = 0;
  uint64_t surfaceId = 0;
  uint64_t windowId = 0;
  JsonRect rect;
  JsonRect sourceRect;
  int32_t z = 0;
  bool visible = true;
  bool hitTest = true;
  bool geometryLocked = false;
};

struct JsonInputLayout {
  uint64_t epoch = 0;
  bool keyboardCapture = false;
  bool exclusiveShellMode = false;
  std::vector<JsonRect> shellRegions;
  std::vector<JsonInputWindow> windows;
};

void require(bool condition, const char *message) {
  if (condition)
    return;
  std::cerr << "wire_cpp_benchmark: " << message << '\n';
  std::exit(1);
}

std::vector<uint8_t> readFile(const std::string &path) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  require(stream.good(), "cannot read FlatBuffer fixture");
  const auto size = stream.tellg();
  require(size >= 0, "cannot size FlatBuffer fixture");
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  stream.seekg(0);
  stream.read(reinterpret_cast<char *>(bytes.data()),
              static_cast<std::streamsize>(bytes.size()));
  require(stream.good(), "cannot load FlatBuffer fixture");
  return bytes;
}

void skipJsonWhitespace(const std::string &payload, size_t &position) {
  while (position < payload.size() &&
         std::isspace(static_cast<unsigned char>(payload[position])))
    ++position;
}

size_t findJsonField(const std::string &payload, const std::string &key,
                     size_t begin = 0, size_t end = std::string::npos) {
  const auto marker = "\"" + key + "\"";
  if (end == std::string::npos || end > payload.size())
    end = payload.size();
  auto position = begin;
  while ((position = payload.find(marker, position)) != std::string::npos &&
         position < end) {
    const auto colon = payload.find(':', position + marker.size());
    if (colon != std::string::npos && colon < end)
      return colon + 1;
    position += marker.size();
  }
  return std::string::npos;
}

std::optional<double> parseJsonNumber(const std::string &payload,
                                      size_t &position, size_t end) {
  skipJsonWhitespace(payload, position);
  if (position >= end)
    return {};
  const char *start = payload.c_str() + position;
  char *stop = nullptr;
  const double value = std::strtod(start, &stop);
  if (stop == start)
    return {};
  position = static_cast<size_t>(stop - payload.c_str());
  return value;
}

std::optional<uint64_t> jsonUintField(const std::string &payload,
                                      const std::string &key) {
  auto position = findJsonField(payload, key);
  if (position == std::string::npos)
    return {};
  skipJsonWhitespace(payload, position);
  const auto start = position;
  while (position < payload.size() &&
         std::isdigit(static_cast<unsigned char>(payload[position])))
    ++position;
  if (start == position)
    return {};
  try {
    return std::stoull(payload.substr(start, position - start));
  } catch (...) {
    return {};
  }
}

std::optional<uint64_t> jsonUintFieldInRange(const std::string &payload,
                                             const std::string &key,
                                             size_t begin, size_t end) {
  auto position = findJsonField(payload, key, begin, end);
  if (position == std::string::npos)
    return {};
  skipJsonWhitespace(payload, position);
  const auto start = position;
  while (position < end &&
         std::isdigit(static_cast<unsigned char>(payload[position])))
    ++position;
  if (start == position)
    return {};
  try {
    return std::stoull(payload.substr(start, position - start));
  } catch (...) {
    return {};
  }
}

std::optional<int32_t> jsonIntFieldInRange(const std::string &payload,
                                           const std::string &key, size_t begin,
                                           size_t end) {
  auto position = findJsonField(payload, key, begin, end);
  if (position == std::string::npos)
    return {};
  const auto value = parseJsonNumber(payload, position, end);
  return value ? std::optional<int32_t>{static_cast<int32_t>(*value)}
               : std::nullopt;
}

std::optional<bool> jsonBoolFieldInRange(const std::string &payload,
                                         const std::string &key, size_t begin,
                                         size_t end) {
  auto position = findJsonField(payload, key, begin, end);
  if (position == std::string::npos)
    return {};
  skipJsonWhitespace(payload, position);
  if (payload.compare(position, 4, "true") == 0)
    return true;
  if (payload.compare(position, 5, "false") == 0)
    return false;
  return {};
}

std::optional<JsonRect> jsonRectFieldInRange(const std::string &payload,
                                             const std::string &key,
                                             size_t begin, size_t end) {
  auto position = findJsonField(payload, key, begin, end);
  if (position == std::string::npos)
    return {};
  position = payload.find('[', position);
  if (position == std::string::npos || position >= end)
    return {};
  ++position;
  JsonRect rect;
  std::array<double *, 4> values = {&rect.x, &rect.y, &rect.width,
                                    &rect.height};
  for (size_t index = 0; index < values.size(); ++index) {
    const auto parsed = parseJsonNumber(payload, position, end);
    if (!parsed)
      return {};
    *values[index] = *parsed;
    skipJsonWhitespace(payload, position);
    if (index + 1 < values.size()) {
      if (position >= end || payload[position] != ',')
        return {};
      ++position;
    }
  }
  skipJsonWhitespace(payload, position);
  return position < end && payload[position] == ']'
             ? std::optional<JsonRect>{rect}
             : std::nullopt;
}

size_t findMatchingJsonBrace(const std::string &payload, size_t openPosition,
                             size_t end) {
  uint32_t depth = 0;
  bool inString = false;
  bool escaped = false;
  for (size_t position = openPosition; position < end; ++position) {
    const char character = payload[position];
    if (inString) {
      if (escaped)
        escaped = false;
      else if (character == '\\')
        escaped = true;
      else if (character == '"')
        inString = false;
      continue;
    }
    if (character == '"')
      inString = true;
    else if (character == '{')
      ++depth;
    else if (character == '}') {
      if (depth == 0)
        return std::string::npos;
      if (--depth == 0)
        return position;
    }
  }
  return std::string::npos;
}

size_t findMatchingJsonArray(const std::string &payload, size_t openPosition) {
  uint32_t depth = 0;
  bool inString = false;
  bool escaped = false;
  for (size_t position = openPosition; position < payload.size(); ++position) {
    const char character = payload[position];
    if (inString) {
      if (escaped)
        escaped = false;
      else if (character == '\\')
        escaped = true;
      else if (character == '"')
        inString = false;
      continue;
    }
    if (character == '"')
      inString = true;
    else if (character == '[')
      ++depth;
    else if (character == ']') {
      if (depth == 0)
        return std::string::npos;
      if (--depth == 0)
        return position;
    }
  }
  return std::string::npos;
}

bool jsonStringFieldEquals(const std::string &payload, const std::string &key,
                           const std::string &expected) {
  auto position = findJsonField(payload, key);
  if (position == std::string::npos)
    return false;
  skipJsonWhitespace(payload, position);
  if (position >= payload.size() || payload[position++] != '"')
    return false;
  const auto start = position;
  while (position < payload.size() && payload[position] != '"')
    ++position;
  return payload.compare(start, position - start, expected) == 0;
}

// This intentionally freezes the removed Runtime.cpp parser's work so the
// migration retains a reproducible native baseline without a runtime JSON
// fallback.
std::shared_ptr<JsonInputLayout>
parseHistoricalInputLayout(const std::string &payload) {
  if (!jsonStringFieldEquals(payload, "type", "input_layout"))
    return nullptr;
  auto snapshot = std::make_shared<JsonInputLayout>();
  snapshot->epoch = jsonUintField(payload, "epoch").value_or(0);
  snapshot->keyboardCapture =
      jsonBoolFieldInRange(payload, "keyboardCapture", 0, payload.size())
          .value_or(false);
  snapshot->exclusiveShellMode =
      jsonBoolFieldInRange(payload, "exclusiveShellMode", 0, payload.size())
          .value_or(false);

  if (const auto shellValue = findJsonField(payload, "shellRegions");
      shellValue != std::string::npos) {
    const auto arrayStart = payload.find('[', shellValue);
    const auto arrayEnd = arrayStart == std::string::npos
                              ? std::string::npos
                              : findMatchingJsonArray(payload, arrayStart);
    if (arrayStart != std::string::npos && arrayEnd != std::string::npos) {
      size_t position = arrayStart + 1;
      while (position < arrayEnd) {
        skipJsonWhitespace(payload, position);
        if (position >= arrayEnd)
          break;
        if (payload[position] == ',') {
          ++position;
          continue;
        }
        if (payload[position] != '{')
          break;
        const auto objectEnd =
            findMatchingJsonBrace(payload, position, arrayEnd);
        if (objectEnd == std::string::npos)
          break;
        if (const auto rect =
                jsonRectFieldInRange(payload, "rect", position, objectEnd))
          snapshot->shellRegions.push_back(*rect);
        position = objectEnd + 1;
      }
    }
  }

  const auto windowsValue = findJsonField(payload, "windows");
  if (windowsValue == std::string::npos)
    return snapshot;
  const auto arrayStart = payload.find('[', windowsValue);
  const auto arrayEnd = arrayStart == std::string::npos
                            ? std::string::npos
                            : findMatchingJsonArray(payload, arrayStart);
  if (arrayStart == std::string::npos || arrayEnd == std::string::npos)
    return nullptr;

  size_t position = arrayStart + 1;
  while (position < arrayEnd) {
    skipJsonWhitespace(payload, position);
    if (position >= arrayEnd)
      break;
    if (payload[position] == ',') {
      ++position;
      continue;
    }
    if (payload[position] != '{')
      break;
    const auto objectEnd = findMatchingJsonBrace(payload, position, arrayEnd);
    if (objectEnd == std::string::npos)
      break;
    const auto objectId =
        jsonUintFieldInRange(payload, "objectId", position, objectEnd);
    const auto rect =
        jsonRectFieldInRange(payload, "rect", position, objectEnd);
    if (objectId && rect) {
      JsonInputWindow window;
      window.objectId = *objectId;
      window.surfaceId =
          jsonUintFieldInRange(payload, "surfaceId", position, objectEnd)
              .value_or(window.objectId);
      window.windowId =
          jsonUintFieldInRange(payload, "windowId", position, objectEnd)
              .value_or(0);
      window.rect = *rect;
      window.sourceRect =
          jsonRectFieldInRange(payload, "sourceRect", position, objectEnd)
              .value_or(window.rect);
      window.z =
          jsonIntFieldInRange(payload, "z", position, objectEnd).value_or(0);
      window.visible =
          jsonBoolFieldInRange(payload, "visible", position, objectEnd)
              .value_or(true);
      window.hitTest =
          jsonBoolFieldInRange(payload, "hitTest", position, objectEnd)
              .value_or(true);
      window.geometryLocked =
          jsonBoolFieldInRange(payload, "geometryLocked", position, objectEnd)
              .value_or(false);
      if (window.visible)
        snapshot->windows.push_back(window);
    }
    position = objectEnd + 1;
  }
  std::sort(snapshot->windows.begin(), snapshot->windows.end(),
            [](const auto &left, const auto &right) {
              return left.z != right.z ? left.z > right.z
                                       : left.objectId > right.objectId;
            });
  return snapshot;
}

std::string dartJsonDouble(double value) {
  std::ostringstream output;
  output << value;
  auto text = output.str();
  if (value == std::trunc(value) &&
      text.find_first_of(".eE") == std::string::npos)
    text += ".0";
  return text;
}

std::string makeJsonInputLayout(size_t count) {
  std::ostringstream payload;
  payload << "{\"type\":\"input_layout\",\"epoch\":" << 0x100000000ULL + count
          << ",\"keyboardCapture\":" << (count % 2 == 1 ? "true" : "false")
          << ",\"exclusiveShellMode\":" << (count == 32 ? "true" : "false")
          << ",\"shellRegions\":[{\"rect\":[-0.5,0.25,177.75,72.5],\"mode\":"
             "\"flutter\"}],\"windows\":[";
  for (size_t index = 0; index < count; ++index) {
    if (index > 0)
      payload << ',';
    payload << "{\"objectId\":" << 0x100000000ULL + index
            << ",\"surfaceId\":" << 0x200000000ULL + index
            << ",\"windowId\":" << 0x300000000ULL + index << ",\"rect\":["
            << dartJsonDouble(-12.5 + index * 3.25) << ','
            << dartJsonDouble(4.75 + index)
            << ",640.5,480.25],\"sourceRect\":[0.25,1.5,1280.5,960.25],\"z\":"
            << index % 5 << ",\"visible\":"
            << (index % 7 != 0 || index == 0 ? "true" : "false")
            << ",\"hitTest\":"
            << (index % 3 != 0 || index == 0 ? "true" : "false")
            << ",\"geometryLocked\":" << (index % 2 == 0 ? "true" : "false")
            << '}';
  }
  payload << "]}";
  return payload.str();
}

std::vector<uint8_t> finish(flatbuffers::FlatBufferBuilder &builder,
                            Wire::Payload type,
                            flatbuffers::Offset<void> payload,
                            uint64_t requestId = 0) {
  const auto envelope = Wire::CreateEnvelope(
      builder, BridgeWire::PROTOCOL_VERSION, 41, requestId, type, payload);
  Wire::FinishEnvelopeBuffer(builder, envelope);
  return {builder.GetBufferPointer(),
          builder.GetBufferPointer() + builder.GetSize()};
}

std::string jsonEscape(const std::string &value) {
  std::string escaped;
  escaped.reserve(value.size() + 8);
  for (const unsigned char character : value) {
    switch (character) {
    case '\\':
      escaped += "\\\\";
      break;
    case '"':
      escaped += "\\\"";
      break;
    case '\b':
      escaped += "\\b";
      break;
    case '\f':
      escaped += "\\f";
      break;
    case '\n':
      escaped += "\\n";
      break;
    case '\r':
      escaped += "\\r";
      break;
    case '\t':
      escaped += "\\t";
      break;
    default:
      escaped += static_cast<char>(character);
      break;
    }
  }
  return escaped;
}

std::string makeJsonWindowResponse(size_t count) {
  std::ostringstream payload;
  payload << "{\"type\":\"windows\",\"requestId\":77,\"windows\":[";
  for (size_t index = 0; index < count; ++index) {
    if (index > 0)
      payload << ',';
    payload << "{\"objectId\":" << 0x100000000ULL + index
            << ",\"objectKind\":\""
            << (index % 2 == 0 ? "root_surface" : "surface")
            << "\",\"surfaceId\":" << 0x200000000ULL + index
            << ",\"windowId\":" << 0x300000000ULL + index
            << ",\"textureId\":" << index + 1
            << ",\"width\":1280,\"height\":960,\"surfaceX\":0.25,\"surfaceY\":"
               "1.5,\"surfaceWidth\":1280.5,\"surfaceHeight\":960.25,"
               "\"textureSourceX\":2.5,\"textureSourceY\":3.75,"
               "\"textureSourceWidth\":1275.5,\"textureSourceHeight\":955.25,"
               "\"geometryX\":-12.5,\"geometryY\":4.75,\"geometryWidth\":640.5,"
               "\"geometryHeight\":480.25,\"monitorId\":"
            << index % 2 << ",\"transform\":" << index % 8
            << ",\"scale120\":120,\"title\":\""
            << jsonEscape("Golden café 🐒 " + std::to_string(index))
            << "\",\"appId\":\""
            << jsonEscape("dev.denial.golden." + std::to_string(index))
            << '"';
    if (index == 0)
      payload << ",\"statusColorArgb\":4279383126";
    payload << '}';
  }
  payload << "]}";
  return payload.str();
}

std::vector<uint8_t> makeFlatWindowResponse(size_t count) {
  flatbuffers::FlatBufferBuilder builder(1024 + count * 256);
  std::vector<flatbuffers::Offset<Wire::Window>> windows;
  windows.reserve(count);
  for (size_t index = 0; index < count; ++index) {
    const auto title =
        builder.CreateString("Golden café 🐒 " + std::to_string(index));
    const auto appId =
        builder.CreateString("dev.denial.golden." + std::to_string(index));
    windows.emplace_back(Wire::CreateWindow(
        builder, 0x100000000ULL + index,
        index % 2 == 0 ? Wire::ObjectKind_RootSurface
                       : Wire::ObjectKind_Surface,
        0x200000000ULL + index, 0x300000000ULL + index, index + 1, title, appId,
        1280, 960, 0.25, 1.5, 1280.5, 960.25, 2.5, 3.75, 1275.5, 955.25, -12.5,
        4.75, 640.5, 480.25, static_cast<int64_t>(index % 2),
        static_cast<uint32_t>(index % 8), 120, 0xff123456U, index == 0));
  }
  const auto snapshot =
      Wire::CreateWindowSnapshot(builder, builder.CreateVector(windows));
  const auto response = Wire::CreateWindowResponse(
      builder, Wire::WindowResponseKind_Windows, true, snapshot);
  return finish(builder, Wire::Payload_WindowResponse, response.Union(), 77);
}

template <typename Operation>
double measure(size_t iterations, Operation operation) {
  for (size_t index = 0; index < 200; ++index)
    operation();
  std::array<double, 5> samples = {};
  for (auto &sample : samples) {
    const auto start = std::chrono::steady_clock::now();
    for (size_t index = 0; index < iterations; ++index)
      operation();
    const auto elapsed = std::chrono::duration<double, std::micro>(
                             std::chrono::steady_clock::now() - start)
                             .count();
    sample = elapsed / static_cast<double>(iterations);
  }
  std::ranges::sort(samples);
  return samples[samples.size() / 2];
}

void benchmarkCount(size_t count) {
  const auto jsonInput = makeJsonInputLayout(count);
  const auto label = count == 1 ? "one" : count == 8 ? "eight" : "many";
  const auto flatInput =
      readFile(std::string("protocol/golden/dart_input_") + label + ".denw");
  const auto jsonWindows = makeJsonWindowResponse(count);
  const auto flatWindows = makeFlatWindowResponse(count);
  const auto expectedJsonInputBytes = count == 1   ? 370U
                                      : count == 8 ? 1767U
                                                   : 6577U;
  if (jsonInput.size() != expectedJsonInputBytes)
    std::cerr << "wire_cpp_benchmark: JSON fixture count=" << count
              << " bytes=" << jsonInput.size()
              << " expected=" << expectedJsonInputBytes << '\n';
  require(jsonInput.size() == expectedJsonInputBytes,
          "historical JSON input fixture drifted");

  const size_t iterations = count == 1 ? 20000 : count == 8 ? 6000 : 1500;
  const auto jsonDecodeUs = measure(iterations, [&] {
    const auto layout = parseHistoricalInputLayout(jsonInput);
    require(layout != nullptr, "historical parser rejected fixture");
    sink = sink ^ layout->epoch ^ layout->windows.size();
  });
  const auto flatVerifyUs = measure(iterations, [&] {
    BridgeWire::ERejectReason reason = BridgeWire::ERejectReason::None;
    const auto owned = BridgeWire::verifyAndOwnIncoming(
        flatInput.data(), flatInput.size(), reason);
    require(owned != nullptr, "FlatBuffer verifier rejected fixture");
    const auto *layout =
        BridgeWire::envelopeFromOwned(*owned)->payload_as_InputLayout();
    sink = sink ^ layout->epoch() ^
           (layout->windows() ? layout->windows()->size() : 0);
  });
  const auto jsonEncodeUs = measure(
      iterations, [&] { sink = sink ^ makeJsonWindowResponse(count).size(); });
  const auto flatEncodeUs = measure(
      iterations, [&] { sink = sink ^ makeFlatWindowResponse(count).size(); });

  std::cout << "CPP count=" << count << " input_json_bytes=" << jsonInput.size()
            << " input_flat_bytes=" << flatInput.size()
            << " input_json_decode_us=" << jsonDecodeUs
            << " input_flat_verify_own_us=" << flatVerifyUs
            << " windows_json_bytes=" << jsonWindows.size()
            << " windows_flat_bytes=" << flatWindows.size()
            << " windows_json_encode_us=" << jsonEncodeUs
            << " windows_flat_encode_us=" << flatEncodeUs << '\n';
}

void benchmarkPlacement() {
  const std::string json =
      "{\"type\":\"window_placement\",\"windowId\":12884901888,\"monitorId\":4,"
      "\"workspaceId\":7,\"phase\":\"update\",\"change\":\"resize\",\"x\":-12."
      "5,\"y\":4.75,\"width\":640.5,"
      "\"height\":480.25}";
  const BridgeWire::SPlacementPacket packet{
      .sequence = 41,
      .windowId = 0x300000000ULL,
      .monitorId = 4,
      .workspaceId = 7,
      .phase = BridgeWire::EPlacementPhase::Update,
      .change = BridgeWire::EPlacementChange::Resize,
      .x = -12.5,
      .y = 4.75,
      .width = 640.5,
      .height = 480.25,
  };
  const auto jsonEncodeUs = measure(20000, [&] {
    std::ostringstream payload;
    payload << "{\"type\":\"window_placement\",\"windowId\":" << packet.windowId
            << ",\"monitorId\":" << packet.monitorId
            << ",\"workspaceId\":" << packet.workspaceId
            << ",\"phase\":\"update\",\"change\":\"resize\",\"x\":" << packet.x
            << ",\"y\":" << packet.y << ",\"width\":" << packet.width
            << ",\"height\":" << packet.height << '}';
    sink = sink ^ payload.str().size();
  });
  const auto fixedEncodeUs = measure(20000, [&] {
    sink = sink ^ BridgeWire::encodePlacement(packet)->size();
  });
  std::cout << "CPP placement_json_bytes=" << json.size()
            << " placement_fixed_bytes=" << BridgeWire::PLACEMENT_PACKET_SIZE
            << " placement_json_encode_us=" << jsonEncodeUs
            << " placement_fixed_encode_us=" << fixedEncodeUs << '\n';
}
} // namespace

int main() {
  for (const size_t count : {1U, 8U, 32U})
    benchmarkCount(count);
  benchmarkPlacement();
  require(sink != std::numeric_limits<uint64_t>::max(),
          "impossible benchmark sink");
  return 0;
}
