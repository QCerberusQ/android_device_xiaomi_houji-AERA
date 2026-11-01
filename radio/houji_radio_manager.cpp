// SPDX-License-Identifier: Apache-2.0
// Native modem startup and storage-operation shutdown, not a cellular provider.
#include <cutils/properties.h>
#include <cutils/sockets.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>

namespace {
constexpr char kStop[] = "/tmp/aera-houji-radio-stop";
constexpr char kLease[] = "/tmp/aera-cellular-operation.lock";
constexpr char kSupervisor[] = "init.svc.aera-houji-radio";
int lease = -1;
bool inhibited = false;

void Log(const char* message) {
    fprintf(stderr, "aera-houji-radio: %s\n", message);
    if (FILE* log = fopen("/tmp/recovery.log", "ae")) {
        fprintf(log, "I:aera-houji-radio::%s\n", message);
        fclose(log);
    }
}

bool PropertyIs(const char* name, const char* expected) {
    char value[PROPERTY_VALUE_MAX];
    property_get(name, value, "");
    return strcmp(value, expected) == 0;
}

bool Stopped() {
    return (PropertyIs(kSupervisor, "stopped") || PropertyIs(kSupervisor, "")) &&
           !PropertyIs("vendor.houji.radio.owned", "1");
}

void ReleaseLease() {
    if (lease >= 0) close(lease);
    lease = -1;
}

bool Ready() {
    return PropertyIs("post.decrypt.modules", "true") &&
           PropertyIs("hwservicemanager.ready", "true") &&
           PropertyIs("servicemanager.ready", "true");
}

void Start() {
    // Keep our lease across ctl.start, before the shell acquires its own lease.
    lease = open(kLease, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lease < 0 || flock(lease, LOCK_SH | LOCK_NB) != 0) {
        ReleaseLease();
        Log("Storage is busy; native radio auto-start skipped for this boot.");
        return;
    }
    if (property_set("ctl.start", "aera-houji-radio") != 0) {
        ReleaseLease();
        Log("Cannot start the native radio supervisor.");
        return;
    }
    Log("Userdata/modules and Binder managers ready; starting native radio.");
}

bool Stop() {
    // A disconnect, even before startup, suppresses auto-start for this boot.
    inhibited = true;
    const int fd = open(kStop, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        Log("Cannot request radio shutdown; storage operation refused.");
        return false;
    }
    close(fd);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    do {
        if (Stopped()) {
            ReleaseLease();
            Log("Native radio is stopped; storage operation may acquire its lease.");
            return true;
        }
        usleep(100000);
    } while (std::chrono::steady_clock::now() < deadline);
    Log("Native radio shutdown did not finish; retaining the storage lease.");
    return false;
}

void Serve(int listener) {
    const int peer = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (peer < 0) return;
    pollfd request{peer, POLLIN, 0};
    if (poll(&request, 1, 1000) > 0 && (request.revents & POLLIN)) {
        char command[64];
        const ssize_t count = recv(peer, command, sizeof(command), MSG_TRUNC);
        const char* reply = "ERR Native radio manager supports disconnect only";
        if (count == 10 && memcmp(command, "disconnect", 10) == 0) {
            reply = Stop() ? "OK" : "ERR Native radio shutdown incomplete";
        }
        send(peer, reply, strlen(reply), MSG_NOSIGNAL);
    }
    close(peer);
}
}  // namespace

int main() {
    const int listener = android_get_control_socket("aera-cellular");
    if (listener < 0 || listen(listener, 4) != 0 ||
        fcntl(listener, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(listener, F_SETFL, O_NONBLOCK) < 0) {
        Log("Cannot listen on init's cellular disconnect socket; radio remains off.");
        return 1;
    }
    inhibited = access(kStop, F_OK) == 0;
    bool attempted = false;
    for (;;) {
        // Service pending disconnects before considering automatic startup.
        pollfd request{listener, POLLIN, 0};
        const int result = poll(&request, 1, 250);
        if (result < 0 && errno != EINTR) {
            Stop();
            return 1;
        }
        if (result > 0 && (request.revents & POLLIN)) Serve(listener);
        if (!inhibited && PropertyIs("sys.usb.config.aera_fastbootd", "1")) Stop();
        if (!inhibited && !attempted && Ready()) {
            attempted = true;
            Start();
        }
        if (lease >= 0 && Stopped()) ReleaseLease();
    }
}
