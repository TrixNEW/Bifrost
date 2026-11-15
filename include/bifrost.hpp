/* Thin C++23 layer over bifrost_plugin.h: member-function callbacks, exceptions kept inside the plugin, and one
   object per plugin that the host deletes at shutdown. Everything here is header-only and optional. */
#ifndef BIFROST_HPP
#define BIFROST_HPP

#include <cstdint>
#include <exception>
#include <format>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "bifrost_plugin.h"

namespace bifrost {

inline bifrost_str str(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

inline std::string_view view(bifrost_str text) noexcept {
    return {reinterpret_cast<const char *>(text.ptr), text.len};
}

/// Thrown from a plugin's constructor to fail its load with this status.
struct Failure : std::exception {
    bifrost_status status;
    explicit Failure(bifrost_status code) noexcept : status(code) {}
    const char *what() const noexcept override { return "bifrost call failed"; }
};

inline void check(bifrost_status status) {
    if (status != BIFROST_STATUS_OK) throw Failure(status);
}

class Host {
public:
    explicit Host(const bifrost_host *raw) noexcept : raw_(raw) {}

    const bifrost_host *raw() const noexcept { return raw_; }

    void log(bifrost_log_level level, std::string_view text) const noexcept { raw_->log(raw_->context, level, str(text)); }

    template <class... Args>
    void log(bifrost_log_level level, std::format_string<Args...> format, Args &&...args) const noexcept {
        try {
            log(level, std::string_view(std::format(format, std::forward<Args>(args)...)));
        } catch (...) {
        }
    }

    void describe(std::string_view description) const noexcept {
        if (BIFROST_HOST_HAS(raw_, set_description)) raw_->set_description(raw_->context, str(description));
    }

    /// Calls (object->*Method)(event, decision) for every event of `kind`.
    template <auto Method, class T>
    void on(bifrost_event_kind kind, T *object) const {
        check(raw_->subscribe(raw_->context, kind, [](void *user, const bifrost_event *event, bifrost_transfer_decision *decision) noexcept {
            guard<T>(user, [&](T &self) { (self.*Method)(*event, decision); });
        }, object));
    }

    /// Calls (object->*Method)(packet), which returns what to do with it. A throwing handler passes the packet on.
    template <auto Method, class T>
    void on_packet(bifrost_direction direction, std::uint32_t id, bifrost_packet_phase phase, std::uint32_t flags, T *object) const {
        check(raw_->subscribe_packet(raw_->context, direction, id, phase, flags, [](void *user, bifrost_packet *packet) noexcept {
            bifrost_packet_action action = BIFROST_PACKET_PASS;
            guard<T>(user, [&](T &self) { action = (self.*Method)(*packet); });
            return action;
        }, object));
    }

    /// Calls (object->*Method)(command, args) for `/name`.
    template <auto Method, class T>
    void command(std::string_view name, std::string_view description, bifrost_command_permission permission, T *object) const {
        // Hosts before revision 8 let anyone run a command whatever its permission
        if (permission != BIFROST_PERMISSION_ANY && !BIFROST_HOST_HAS(raw_, revision)) throw Failure(BIFROST_STATUS_UNSUPPORTED);
        bifrost_command_info info{};
        info.struct_size = sizeof(info);
        info.permission = permission;
        info.name = str(name);
        info.description = str(description);
        info.callback = [](void *user, const bifrost_command *request) noexcept {
            guard<T>(user, [&](T &self) { (self.*Method)(*request, view(request->args)); });
        };
        info.user = object;
        check(raw_->register_command_info(raw_->context, &info));
    }

    std::optional<bifrost_player_info> player_info(bifrost_player player) const noexcept {
        if (!BIFROST_HOST_HAS(raw_, player_info)) return std::nullopt;
        bifrost_player_info info{};
        if (raw_->player_info(raw_->context, player, &info, sizeof(info)) != BIFROST_STATUS_OK) return std::nullopt;
        return info;
    }

    std::optional<bifrost_player> find_player(std::string_view name_or_xuid) const noexcept {
        if (!BIFROST_HOST_HAS(raw_, find_player)) return std::nullopt;
        bifrost_player player{};
        if (raw_->find_player(raw_->context, str(name_or_xuid), &player) != BIFROST_STATUS_OK) return std::nullopt;
        return player;
    }

    bifrost_status message(bifrost_player player, std::string_view text) const noexcept {
        return raw_->send_message(raw_->context, player, str(text));
    }

    bifrost_status disconnect(bifrost_player player, std::string_view reason) const noexcept {
        if (!BIFROST_HOST_HAS(raw_, disconnect)) return BIFROST_STATUS_UNSUPPORTED;
        return raw_->disconnect(raw_->context, player, str(reason), nullptr, nullptr);
    }

private:
    // An exception crossing back into the host would be undefined behaviour, so it ends here
    template <class T, class F>
    static void guard(void *user, F &&call) noexcept {
        try {
            call(*static_cast<T *>(user));
        } catch (...) {
        }
    }

    const bifrost_host *raw_;
};

/// Builds T(Host, bifrost_plugin&) at load and deletes it at shutdown. A throwing constructor fails the load.
template <class T>
bifrost_status init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION || !BIFROST_HOST_HAS(host, register_command_info)) return BIFROST_STATUS_INCOMPATIBLE;
    try {
        plugin->state = new T(Host(host), *plugin);
        plugin->shutdown = [](void *state) noexcept { delete static_cast<T *>(state); };
        return BIFROST_STATUS_OK;
    } catch (const Failure &failure) {
        return failure.status == BIFROST_STATUS_OK ? BIFROST_STATUS_FAILED : failure.status;
    } catch (...) {
        return BIFROST_STATUS_FAILED;
    }
}

}

#define BIFROST_PLUGIN(T)                                                                                          \
    extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) \
        BIFROST_NOEXCEPT {                                                                                         \
        return ::bifrost::init<T>(host, plugin);                                                                   \
    }

#endif
