#pragma once

#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <wayland-server.h>
#include "../../helpers/signal/Signal.hpp"
#include <hyprutils/os/FileDescriptor.hpp>

#include "EventLoopTimer.hpp"

namespace Aquamarine {
    struct SPollFD;
};

struct SEventLoopDoLaterLock {
    SEventLoopDoLaterLock(uint64_t seq);
    ~SEventLoopDoLaterLock();

    uint64_t seq = 0;
};

class CEventLoopAsyncSignal {
  public:
    ~CEventLoopAsyncSignal();

    bool signal() const;

  private:
    CEventLoopAsyncSignal(wl_event_loop* loop, void (*callback)(void*), void* data);
    static int onReadable(int fd, uint32_t mask, void* data);

    Hyprutils::OS::CFileDescriptor m_eventfd;
    wl_event_source*               m_eventSource = nullptr;
    void (*m_callback)(void*)                    = nullptr;
    void* m_data                                 = nullptr;

    friend class CEventLoopManager;
};

class CEventLoopManager {
  public:
    CEventLoopManager(wl_display* display, wl_event_loop* wlEventLoop);
    ~CEventLoopManager();

    void enterLoop();

    // Note: will remove the timer if the ptr is lost.
    void addTimer(SP<CEventLoopTimer> timer);
    void removeTimer(SP<CEventLoopTimer> timer);

    void onTimerFire();

    // schedules a recalc of the timers
    void scheduleRecalc();

    // schedules a function to run later, aka in a wayland idle event. Returns a sequence which can be used to remove it.
    uint64_t doLater(const std::function<void()>& fn);
    void     removeDoLater(uint64_t seq);

    // automatically cleaned up doLater instance
    [[nodiscard]] UP<SEventLoopDoLaterLock> doLaterLock(const std::function<void()>& fn);

    // Thread-safe post primitive for foreign runtimes embedded in the Hyprland
    // process. The callback is executed on the Wayland event-loop thread.
    void postToLoop(std::function<void()>&& fn);
    void wakeFromAnyThread();
    void onWake();

    // One persistent, allocation-free event-loop handoff for a foreign thread.
    SP<CEventLoopAsyncSignal> createAsyncSignal(void (*callback)(void*), void* data);

    struct SIdleData {
        wl_event_source*                                        eventSource = nullptr;
        std::vector<std::pair<uint64_t, std::function<void()>>> fns;
    };

    struct SReadableWaiter {
        wl_event_source*               source;
        Hyprutils::OS::CFileDescriptor fd;
        std::function<void()>          fn;

        SReadableWaiter(wl_event_source* src, Hyprutils::OS::CFileDescriptor f, std::function<void()> func) : source(src), fd(std::move(f)), fn(std::move(func)) {}

        ~SReadableWaiter() {
            if (source) {
                wl_event_source_remove(source);
                source = nullptr;
            }
        }

        // copy
        SReadableWaiter(const SReadableWaiter&)            = delete;
        SReadableWaiter& operator=(const SReadableWaiter&) = delete;

        // move
        SReadableWaiter(SReadableWaiter&& other) noexcept            = default;
        SReadableWaiter& operator=(SReadableWaiter&& other) noexcept = default;
    };

    // schedule function to when fd is readable (WL_EVENT_READABLE / POLLIN),
    // takes ownership of fd
    void doOnReadable(Hyprutils::OS::CFileDescriptor fd, std::function<void()>&& fn);
    void onFdReadable(SReadableWaiter* waiter);
    void onFdReadableFail(SReadableWaiter* waiter);

  private:
    // Manages the event sources after AQ pollFDs change.
    void syncPollFDs();
    void nudgeTimers();

    struct SEventSourceData {
        SP<Aquamarine::SPollFD> pollFD;
        wl_event_source*        eventSource = nullptr;
    };

    struct {
        wl_event_loop*   loop        = nullptr;
        wl_display*      display     = nullptr;
        wl_event_source* eventSource = nullptr;
    } m_wayland;

    struct {
        std::vector<SP<CEventLoopTimer>> timers;
        Hyprutils::OS::CFileDescriptor   timerfd;
        bool                             recalcScheduled = false;
    } m_timers;

    struct {
        Hyprutils::OS::CFileDescriptor    eventfd;
        wl_event_source*                  eventSource = nullptr;
        std::mutex                        mutex;
        std::deque<std::function<void()>> pending;
    } m_wake;

    SIdleData                        m_idle;
    std::map<int, SEventSourceData>  m_aqEventSources;
    std::vector<UP<SReadableWaiter>> m_readableWaiters;

    struct {
        CHyprSignalListener pollFDsChanged;
    } m_listeners;

    wl_event_source* m_configWatcherInotifySource = nullptr;

    friend class CAsyncDialogBox;
    friend class CMainLoopExecutor;
};

inline UP<CEventLoopManager> g_pEventLoopManager;
