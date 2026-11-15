#include <atomic>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>

#include "bifrost.hpp"
#include "bifrost_manifest.h"

static_assert(std::is_nothrow_invocable_v<bifrost_event_fn, void *, const bifrost_event *, bifrost_transfer_decision *>);
static_assert(std::is_nothrow_invocable_v<bifrost_command_fn, void *, const bifrost_command *>);
static_assert(std::is_nothrow_invocable_r_v<bifrost_status, decltype(&bifrost_plugin_init), const bifrost_host *, bifrost_plugin *>);

namespace {

std::atomic<std::uint32_t> events;
std::atomic<std::uint32_t> caught;
std::atomic<std::uint32_t> shutdowns;
std::string last_args;

class Fixture {
public:
    Fixture(bifrost::Host host, bifrost_plugin &plugin) : host_(host) {
        plugin.name = bifrost::str("cpp-fixture");
        plugin.plugin_version = bifrost::str("1.0.0");
        plugin.capabilities = BIFROST_CAPABILITY_EVENTS | BIFROST_CAPABILITY_COMMANDS;
        host_.describe("Built as C++23");
        host_.on<&Fixture::connected>(BIFROST_EVENT_PLAYER_CONNECTED, this);
        host_.command<&Fixture::echo>("echo", "", BIFROST_PERMISSION_ANY, this);
    }

    ~Fixture() { shutdowns++; }

private:
    void connected(const bifrost_event &event, bifrost_transfer_decision *) {
        if (event.kind == BIFROST_EVENT_PLAYER_CONNECTED) events++;
    }

    // Rethrows, so the wrapper has to stop it before the host
    void echo(const bifrost_command &, std::string_view args) {
        try {
            if (args.empty()) throw std::invalid_argument("no args");
            last_args.assign(args);
        } catch (const std::exception &) {
            caught++;
            throw;
        }
    }

    bifrost::Host host_;
};

}

BIFROST_PLUGIN(Fixture)

extern "C" {

BIFROST_EXPORT std::uint32_t bifrost_fixture_events() noexcept {
    return events;
}

BIFROST_EXPORT std::uint32_t bifrost_fixture_caught() noexcept {
    return caught;
}

BIFROST_EXPORT std::uint32_t bifrost_fixture_shutdowns() noexcept {
    return shutdowns;
}

BIFROST_EXPORT std::size_t bifrost_fixture_args(char *out, std::size_t capacity) noexcept {
    std::size_t len = last_args.size() < capacity ? last_args.size() : capacity;
    last_args.copy(out, len);
    return len;
}

BIFROST_EXPORT std::size_t bifrost_fixture_host_size() noexcept {
    return sizeof(bifrost_host);
}

}
