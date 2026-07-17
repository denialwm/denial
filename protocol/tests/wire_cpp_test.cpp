#include "../../Hyprland/deniald/Wire.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <limits>
#include <span>
#include <string>
#include <vector>

namespace {
using namespace Denial;

constexpr const char *GOLDEN_ROOT = "protocol/golden";

[[noreturn]] void fail(const std::string &message) {
  std::cerr << "wire_cpp_test: " << message << '\n';
  std::exit(1);
}

void require(bool condition, const std::string &message) {
  if (!condition)
    fail(message);
}

std::vector<uint8_t> readFile(const std::string &path) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  require(stream.good(), "cannot read " + path);
  const auto size = stream.tellg();
  require(size >= 0, "cannot size " + path);
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  stream.seekg(0);
  stream.read(reinterpret_cast<char *>(bytes.data()), size);
  require(stream.good(), "cannot load " + path);
  return bytes;
}

void writeFile(const std::string &path, std::span<const uint8_t> bytes) {
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  require(stream.good(), "cannot write " + path);
  stream.write(reinterpret_cast<const char *>(bytes.data()),
               static_cast<std::streamsize>(bytes.size()));
  require(stream.good(), "cannot finish " + path);
}

std::vector<uint8_t> finish(flatbuffers::FlatBufferBuilder &builder,
                            Wire::Payload type,
                            flatbuffers::Offset<void> payload,
                            uint64_t requestId = 0,
                            uint16_t version = BridgeWire::PROTOCOL_VERSION,
                            uint64_t sequence = 41) {
  const auto envelope = Wire::CreateEnvelope(builder, version, sequence,
                                             requestId, type, payload);
  Wire::FinishEnvelopeBuffer(builder, envelope);
  return {builder.GetBufferPointer(),
          builder.GetBufferPointer() + builder.GetSize()};
}

std::vector<uint8_t> makeWindowResponse(size_t count) {
  flatbuffers::FlatBufferBuilder builder(1024 + count * 256);
  std::vector<flatbuffers::Offset<Wire::Window>> windows;
  windows.reserve(count);
  for (size_t index = 0; index < count; ++index) {
    const auto title =
        builder.CreateString("Golden café 🐒 " + std::to_string(index));
    const auto appId =
        builder.CreateString("dev.denial.golden." + std::to_string(index));
    std::vector<flatbuffers::Offset<Wire::SurfaceLayer>> surfaces;
    surfaces.emplace_back(Wire::CreateSurfaceLayer(
        builder, 0x200000000ULL + index, 0, 0, Wire::SurfaceRole_Root,
        index + 1, 1280, 960, 0.25, 1.5, 1280.5, 960.25, 2.5, 3.75,
        1275.5, 955.25, static_cast<uint32_t>(index % 8), 120, 0));
    if (index == 0) {
      surfaces.emplace_back(Wire::CreateSurfaceLayer(
          builder, 0x400000000ULL, 0x200000000ULL, 0x400000000ULL,
          Wire::SurfaceRole_Popup, 100, 320, 240, 100.25, 80.5, 320, 240, 0,
          0, 320, 240, 0, 120, 1));
    }
    windows.emplace_back(Wire::CreateWindow(
        builder, 0x100000000ULL + index,
        index % 2 == 0 ? Wire::ObjectKind_RootSurface
                       : Wire::ObjectKind_Surface,
        0x200000000ULL + index, 0x300000000ULL + index, index + 1, title, appId,
        1280, 960, 0.25, 1.5, 1280.5, 960.25, 2.5, 3.75, 1275.5, 955.25, -12.5,
        4.75, 640.5, 480.25, static_cast<int64_t>(index % 2),
        static_cast<uint32_t>(index % 8), 120, 0xff123456U, index == 0, 0.25,
        1.5, 1280.5, 960.25, builder.CreateVector(surfaces)));
  }
  const auto snapshot =
      Wire::CreateWindowSnapshot(builder, builder.CreateVector(windows));
  const auto response = Wire::CreateWindowResponse(
      builder, Wire::WindowResponseKind_Windows, true, snapshot);
  return finish(builder, Wire::Payload_WindowResponse, response.Union(), 77);
}

std::vector<uint8_t> makeInputLayout(
    uint16_t version = BridgeWire::PROTOCOL_VERSION,
    Wire::Payload payloadType = Wire::Payload_InputLayout,
    Wire::WindowRequestKind requestKind = Wire::WindowRequestKind_ListWindows) {
  flatbuffers::FlatBufferBuilder builder(256);
  if (payloadType == Wire::Payload_WindowRequest) {
    const auto request = Wire::CreateWindowRequest(builder, requestKind);
    return finish(builder, payloadType, request.Union(), 1, version);
  }
  const auto layout = Wire::CreateInputLayout(builder);
  return finish(builder, payloadType, layout.Union(), 0, version);
}

void verifyDartGoldens() {
  const std::array names = {"empty", "one", "eight", "many"};
  const std::array<size_t, 4> expectedCounts = {0, 1, 8, 32};
  const std::array<uint32_t, 4> expectedFlags = {
      0, BridgeWire::INPUT_LAYOUT_KEYBOARD_CAPTURE, 0,
      BridgeWire::INPUT_LAYOUT_EXCLUSIVE_SHELL};
  for (size_t index = 0; index < names.size(); ++index) {
    const auto bytes = readFile(std::string(GOLDEN_ROOT) + "/dart_input_" +
                                names[index] + ".denw");
    BridgeWire::ERejectReason reason = BridgeWire::ERejectReason::None;
    const auto *envelope =
        BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason);
    require(envelope != nullptr, "Dart input golden rejected");
    const auto *layout = envelope->payload_as_InputLayout();
    require(layout != nullptr && layout->windows() &&
                layout->windows()->size() == expectedCounts[index],
            "Dart input golden window count mismatch");
    require(layout->flags() == expectedFlags[index],
            "Dart input golden layout flags mismatch");
    if (expectedCounts[index] > 0) {
      require(layout->shell_regions() && layout->shell_regions()->size() == 1,
              "Dart input golden shell region mismatch");
      const auto *first = layout->windows()->Get(0);
      const auto expectedFirst = expectedCounts[index] == 1   ? 0ULL
                                 : expectedCounts[index] == 8 ? 4ULL
                                                              : 29ULL;
      require(first && first->object_id() == 0x100000000ULL + expectedFirst &&
                  first->surface_id() == 0x200000000ULL + expectedFirst &&
                  first->window_id() == 0x300000000ULL + expectedFirst &&
                  first->rect().x() == -12.5 + expectedFirst * 3.25,
              "Dart input golden identity or contents mismatch");

      const auto *windows = layout->windows();
      for (flatbuffers::uoffset_t windowIndex = 1;
           windowIndex < windows->size(); ++windowIndex) {
        const auto *previous = windows->Get(windowIndex - 1);
        const auto *current = windows->Get(windowIndex);
        require(previous && current &&
                    (previous->z() > current->z() ||
                     (previous->z() == current->z() &&
                      previous->surface_id() > current->surface_id())),
                "Dart input golden z-order mismatch");
      }

      if (expectedCounts[index] == 32) {
        const Wire::InputWindowRegion *hit = nullptr;
        for (const auto *window : *windows) {
          const auto &rect = window->rect();
          if ((window->flags() & BridgeWire::INPUT_WINDOW_VISIBLE) != 0 &&
              (window->flags() & BridgeWire::INPUT_WINDOW_HIT_TEST_DISABLED) == 0 &&
              rect.x() <= 100.0 && rect.y() <= 100.0 &&
              rect.x() + rect.width() > 100.0 &&
              rect.y() + rect.height() > 100.0) {
            hit = window;
            break;
          }
        }
        require(hit && hit->object_id() == 0x100000000ULL + 29,
                "Dart input golden topmost hit target changed");
        const auto lockedIt =
            std::ranges::find_if(*windows, [](const auto *window) {
              return window && window->object_id() == 0x100000000ULL + 28;
            });
        require(lockedIt != windows->end() &&
                    ((*lockedIt)->flags() &
                     BridgeWire::INPUT_WINDOW_GEOMETRY_LOCKED) != 0,
                "Dart input golden geometry-lock flag changed");
      }
    }
  }
}

void verifyCppGoldens(bool writeGoldens) {
  const std::array names = {"empty", "one", "eight", "many"};
  const std::array<size_t, 4> counts = {0, 1, 8, 32};
  for (size_t index = 0; index < names.size(); ++index) {
    const auto bytes = makeWindowResponse(counts[index]);
    const auto path =
        std::string(GOLDEN_ROOT) + "/cpp_windows_" + names[index] + ".denw";
    if (writeGoldens) {
      writeFile(path, bytes);
      continue;
    }
    require(readFile(path) == bytes, "C++ golden is stale: " + path);
    flatbuffers::Verifier verifier(bytes.data(), bytes.size());
    require(Wire::VerifyEnvelopeBuffer(verifier),
            "C++ golden failed generated verifier");
  }
}

void verifyBadBuffers() {
  BridgeWire::ERejectReason reason = BridgeWire::ERejectReason::None;
  require(!BridgeWire::verifyIncoming(nullptr, 0, reason) &&
              reason == BridgeWire::ERejectReason::Size,
          "empty buffer accepted");

  auto valid = makeInputLayout();
  auto owned =
      BridgeWire::verifyAndOwnIncoming(valid.data(), valid.size(), reason);
  require(owned && BridgeWire::envelopeFromOwned(*owned),
          "verified buffer was not owned");
  valid.assign(valid.size(), 0);
  require(BridgeWire::envelopeFromOwned(*owned)->payload_as_InputLayout(),
          "owned buffer changed with callback storage");

  valid = makeInputLayout();
  require(!BridgeWire::verifyIncoming(valid.data(), 7, reason) &&
              reason == BridgeWire::ERejectReason::Size,
          "truncated buffer accepted");

  auto wrongIdentifier = valid;
  wrongIdentifier[4] ^= 0xff;
  require(!BridgeWire::verifyIncoming(wrongIdentifier.data(),
                                      wrongIdentifier.size(), reason) &&
              reason == BridgeWire::ERejectReason::FlatBuffer,
          "wrong identifier accepted");

  auto wrongVersion = makeInputLayout(2);
  require(!BridgeWire::verifyIncoming(wrongVersion.data(), wrongVersion.size(),
                                      reason) &&
              reason == BridgeWire::ERejectReason::Version,
          "wrong version accepted");

  {
    flatbuffers::FlatBufferBuilder builder;
    const auto layout = Wire::CreateInputLayout(builder);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union(), 0,
               BridgeWire::PROTOCOL_VERSION, 0);
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Sequence,
            "zero sequence accepted");
  }

  auto wrongDirection = makeWindowResponse(1);
  require(!BridgeWire::verifyIncoming(wrongDirection.data(),
                                      wrongDirection.size(), reason) &&
              reason == BridgeWire::ERejectReason::Direction,
          "native-only payload accepted inbound");

  auto invalidEnum =
      makeInputLayout(BridgeWire::PROTOCOL_VERSION, Wire::Payload_WindowRequest,
                      static_cast<Wire::WindowRequestKind>(99));
  require(!BridgeWire::verifyIncoming(invalidEnum.data(), invalidEnum.size(),
                                      reason) &&
              reason == BridgeWire::ERejectReason::Enumeration,
          "invalid enum accepted");

  {
    flatbuffers::FlatBufferBuilder builder;
    const auto layout = Wire::CreateInputLayout(builder);
    const auto bytes =
        finish(builder, static_cast<Wire::Payload>(99), layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason),
            "invalid payload kind accepted");
  }

  std::vector<uint8_t> oversized(BridgeWire::MAX_MESSAGE_BYTES + 1, 0);
  require(
      !BridgeWire::verifyIncoming(oversized.data(), oversized.size(), reason) &&
          reason == BridgeWire::ERejectReason::Size,
      "oversized message accepted");

  {
    flatbuffers::FlatBufferBuilder builder;
    std::vector<Wire::InputWindowRegion> windows(BridgeWire::MAX_REGIONS + 1);
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, nullptr, &windows);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Count,
            "oversized vector accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect nanRect{0, 0, std::numeric_limits<double>::quiet_NaN(),
                                 10};
    std::vector<Wire::WireRect> regions = {nanRect};
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, &regions, nullptr);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Geometry,
            "NaN geometry accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect infiniteRect{
        0, 0, std::numeric_limits<double>::infinity(), 10};
    std::vector<Wire::WireRect> regions = {infiniteRect};
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, &regions, nullptr);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Geometry,
            "infinite geometry accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect subpixelRect{10, 20, 0.25, 0.5};
    std::vector<Wire::WireRect> regions = {subpixelRect};
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, &regions, nullptr);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason),
            "positive subpixel routing geometry rejected");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect emptyRect{10, 20, 0, 0.5};
    std::vector<Wire::WireRect> regions = {emptyRect};
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, &regions, nullptr);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Geometry,
            "empty routing geometry accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect rect{0, 0, 10, 10};
    std::vector<Wire::InputWindowRegion> windows = {Wire::InputWindowRegion{
        0, 2, 3, rect, rect, 0, BridgeWire::INPUT_WINDOW_VISIBLE}};
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, nullptr, &windows);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Identity,
            "missing identity accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect rect{0, 0, 10, 10};
    constexpr uint32_t unknownFlag = 1U << 31;
    std::vector<Wire::InputWindowRegion> windows = {
        Wire::InputWindowRegion{1, 2, 3, rect, rect, 0,
                                BridgeWire::INPUT_WINDOW_VISIBLE | unknownFlag},
    };
    const auto layout = Wire::CreateInputLayoutDirect(
        builder, 1, BridgeWire::INPUT_LAYOUT_KEYBOARD_CAPTURE | unknownFlag,
        nullptr, &windows);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    const auto *envelope =
        BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason);
    require(envelope && envelope->payload_as_InputLayout(),
            "forward-compatible input flags rejected");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const Wire::WireRect rect{0, 0, 10, 10};
    std::vector<Wire::InputWindowRegion> windows = {
        Wire::InputWindowRegion{1, 2, 3, rect, rect, 1,
                                BridgeWire::INPUT_WINDOW_VISIBLE},
        Wire::InputWindowRegion{4, 5, 6, rect, rect, 2,
                                BridgeWire::INPUT_WINDOW_VISIBLE},
    };
    const auto layout =
        Wire::CreateInputLayoutDirect(builder, 1, 0, nullptr, &windows);
    const auto bytes =
        finish(builder, Wire::Payload_InputLayout, layout.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::Ordering,
            "unsorted hit-test windows accepted");
  }

  {
    flatbuffers::FlatBufferBuilder builder;
    const auto text = builder.CreateString(
        std::string(BridgeWire::MAX_STRING_BYTES + 1, 'x'));
    const auto command = Wire::CreateKeyboardCommand(
        builder, Wire::KeyboardCommandKind_Text, text);
    const auto bytes =
        finish(builder, Wire::Payload_KeyboardCommand, command.Union());
    require(!BridgeWire::verifyIncoming(bytes.data(), bytes.size(), reason) &&
                reason == BridgeWire::ERejectReason::String,
            "oversized string accepted");
  }
}

void verifyPlacementPacket() {
  const BridgeWire::SPlacementPacket packet{
      .sequence = 9,
      .windowId = 0x100000002ULL,
      .monitorId = 4,
      .workspaceId = 7,
      .phase = BridgeWire::EPlacementPhase::End,
      .change = BridgeWire::EPlacementChange::Move,
      .x = -12.5,
      .y = 4.75,
      .width = 640.5,
      .height = 480.25,
  };
  const auto encoded = BridgeWire::encodePlacement(packet);
  require(encoded.has_value() &&
              encoded->size() == BridgeWire::PLACEMENT_PACKET_SIZE,
          "placement encode failed");
  const auto decoded =
      BridgeWire::decodePlacement(encoded->data(), encoded->size());
  require(decoded && decoded->sequence == packet.sequence &&
              decoded->windowId == packet.windowId &&
              decoded->monitorId == packet.monitorId &&
              decoded->workspaceId == packet.workspaceId &&
              decoded->x == packet.x && decoded->height == packet.height,
          "placement round trip failed");

  auto malformed = *encoded;
  malformed[0] = 'X';
  require(!BridgeWire::decodePlacement(malformed.data(), malformed.size()),
          "bad placement magic accepted");
  malformed = *encoded;
  malformed[44] = 9;
  require(!BridgeWire::decodePlacement(malformed.data(), malformed.size()),
          "bad placement phase accepted");
  malformed = *encoded;
  malformed[45] = 9;
  require(!BridgeWire::decodePlacement(malformed.data(), malformed.size()),
          "bad placement change accepted");
  malformed = *encoded;
  malformed[46] = 1;
  require(!BridgeWire::decodePlacement(malformed.data(), malformed.size()),
          "nonzero placement reserved field accepted");
  require(!BridgeWire::decodePlacement(encoded->data(), encoded->size() - 1),
          "truncated placement accepted");
}

void verifyDragIconPacket() {
  const BridgeWire::SDragIconPacket packet{
      .sequence = 10,
      .active = true,
      .surfaceId = 0x200000004ULL,
      .textureId = 7,
      .width = 320,
      .height = 240,
      .transform = 0,
      .scale120 = 120,
      .offsetX = -12.5,
      .offsetY = 8.25,
      .surfaceWidth = 160.0,
      .surfaceHeight = 120.0,
      .textureSourceX = 1.0,
      .textureSourceY = 2.0,
      .textureSourceWidth = 319.0,
      .textureSourceHeight = 238.0,
  };
  const auto encoded = BridgeWire::encodeDragIcon(packet);
  require(encoded.has_value() &&
              encoded->size() == BridgeWire::DRAG_ICON_PACKET_SIZE,
          "drag icon encode failed");
  const auto decoded =
      BridgeWire::decodeDragIcon(encoded->data(), encoded->size());
  require(decoded && decoded->sequence == packet.sequence && decoded->active &&
              decoded->surfaceId == packet.surfaceId &&
              decoded->textureId == packet.textureId &&
              decoded->offsetX == packet.offsetX &&
              decoded->surfaceHeight == packet.surfaceHeight &&
              decoded->textureSourceWidth == packet.textureSourceWidth,
          "drag icon round trip failed");

  const auto inactiveEncoded = BridgeWire::encodeDragIcon(
      BridgeWire::SDragIconPacket{.sequence = 11});
  require(inactiveEncoded.has_value(), "inactive drag icon encode failed");
  const auto inactive = BridgeWire::decodeDragIcon(
      inactiveEncoded->data(), inactiveEncoded->size());
  require(inactive && inactive->sequence == 11 && !inactive->active,
          "inactive drag icon round trip failed");

  auto malformed = *encoded;
  malformed[0] = 'X';
  require(!BridgeWire::decodeDragIcon(malformed.data(), malformed.size()),
          "bad drag icon magic accepted");
  malformed = *encoded;
  malformed[24] = 1;
  require(!BridgeWire::decodeDragIcon(malformed.data(), malformed.size()),
          "nonzero drag icon reserved field accepted");
  malformed = *encoded;
  malformed[52] = 8;
  require(!BridgeWire::decodeDragIcon(malformed.data(), malformed.size()),
          "bad drag icon transform accepted");
  malformed = *encoded;
  malformed[44] = 10;
  malformed[45] = 0;
  require(!BridgeWire::decodeDragIcon(malformed.data(), malformed.size()),
          "out-of-bounds drag icon crop accepted");
  require(!BridgeWire::decodeDragIcon(encoded->data(), encoded->size() - 1),
          "truncated drag icon accepted");

  auto invalid = packet;
  invalid.sequence = 0;
  require(!BridgeWire::encodeDragIcon(invalid),
          "zero drag icon sequence encoded");
  invalid = packet;
  invalid.transform = 8;
  require(!BridgeWire::encodeDragIcon(invalid),
          "bad drag icon transform encoded");
}
} // namespace

int main(int argc, char **argv) {
  const bool writeGoldens =
      argc == 2 && std::string_view(argv[1]) == "--write-goldens";
  verifyCppGoldens(writeGoldens);
  if (writeGoldens)
    return 0;
  verifyDartGoldens();
  verifyBadBuffers();
  verifyPlacementPacket();
  verifyDragIconPacket();
  std::cout << "wire_cpp_test: all checks passed\n";
  return 0;
}
