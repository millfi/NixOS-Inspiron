#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define INPUT_DIR "/dev/input"
#define MAX_DEVICES 64
#define LONG_HOLD_SECONDS 10.0
#define REPORT_INTERVAL 60.0
#define RETRY_INTERVAL 60.0

struct device {
    int fd;
    char path[256];
    char name[256];
    unsigned long long key_down, key_up, key_repeat, syn_dropped, read_errors;
    unsigned long long long_hold_warnings;
    bool pressed[KEY_MAX + 1];
    bool warned[KEY_MAX + 1];
    double pressed_since[KEY_MAX + 1];
    double last_report;
};

struct retry_entry {
    char path[256];
    double retry_at;
};

static struct device devices[MAX_DEVICES];
static size_t device_count;
static struct retry_entry retries[MAX_DEVICES];
static size_t retry_count;
static volatile sig_atomic_t stopping;

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void json_string(const char *value) {
    putchar('"');
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (*p == '"' || *p == '\\') {
            putchar('\\');
            putchar(*p);
        } else if (*p < 0x20) {
            printf("\\u%04x", *p);
        } else {
            putchar(*p);
        }
    }
    putchar('"');
}

static void log_prefix(const char *event) {
    struct timespec ts;
    struct tm utc;
    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &utc);
    printf("{\"time\":\"%04d-%02d-%02dT%02d:%02d:%02d.%03ldZ\",\"event\":\"",
           utc.tm_year + 1900, utc.tm_mon + 1, utc.tm_mday,
           utc.tm_hour, utc.tm_min, utc.tm_sec, ts.tv_nsec / 1000000);
    // Finish the event string and separate it from subsequent fields.
    for (const char *p = event; *p; ++p) {
        if (*p == '"' || *p == '\\') putchar('\\');
        putchar(*p);
    }
    printf("\"");
}

static size_t held_count(const struct device *device, double *oldest) {
    size_t count = 0;
    *oldest = 0.0;
    double now = monotonic_seconds();
    for (int code = 0; code <= KEY_MAX; ++code) {
        if (device->pressed[code]) {
            double held = now - device->pressed_since[code];
            if (held > *oldest) *oldest = held;
            ++count;
        }
    }
    return count;
}

static void log_held_fields(const struct device *device) {
    double oldest;
    size_t held = held_count(device, &oldest);
    printf(",\"held_keys\":%zu,\"oldest_held_seconds\":%.1f,"
           "\"long_hold_warnings\":%llu", held, oldest,
           device->long_hold_warnings);
}

static void log_device_summary(const char *event, const struct device *device,
                               const char *reason) {
    log_prefix(event);
    printf(",\"path\":"); json_string(device->path);
    printf(",\"name\":"); json_string(device->name);
    if (reason) {
        printf(",\"reason\":"); json_string(reason);
    }
    printf(",\"key_down\":%llu,\"key_up\":%llu,\"key_repeat\":%llu,"
           "\"syn_dropped\":%llu,\"read_errors\":%llu",
           device->key_down, device->key_up, device->key_repeat,
           device->syn_dropped, device->read_errors);
    log_held_fields(device);
    puts("}");
    fflush(stdout);
}

static bool is_keyboard(int fd) {
    unsigned long bits[KEY_MAX / (8 * sizeof(unsigned long)) + 1] = {0};
    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(bits)), bits) < 0) return false;
    const int alpha[] = {30,31,32,33,36,37,38,16,17,18,19,20,21,22,
                         23,24,25,44,45,46,47,48,49,50,51,52};
    int supported = 0;
    for (size_t i = 0; i < sizeof(alpha) / sizeof(alpha[0]); ++i)
        if (bits[alpha[i] / (8 * sizeof(unsigned long))] &
            (1UL << (alpha[i] % (8 * sizeof(unsigned long))))) ++supported;
    return supported >= 12;
}

static void sync_pressed_state(struct device *device, double now) {
    unsigned long bits[KEY_MAX / (8 * sizeof(unsigned long)) + 1] = {0};
    if (ioctl(device->fd, EVIOCGKEY(sizeof(bits)), bits) < 0) {
        ++device->read_errors;
        log_prefix("key_state_resync_error");
        printf(",\"path\":"); json_string(device->path);
        printf(",\"name\":"); json_string(device->name);
        printf(",\"errno\":%d}\n", errno);
        fflush(stdout);
        return;
    }
    for (int code = 0; code <= KEY_MAX; ++code) {
        bool down = bits[code / (8 * sizeof(unsigned long))] &
                    (1UL << (code % (8 * sizeof(unsigned long))));
        if (down && !device->pressed[code]) device->pressed_since[code] = now;
        if (!down) device->warned[code] = false;
        device->pressed[code] = down;
    }
}

static void close_device(size_t index, const char *reason) {
    struct device device = devices[index];
    close(device.fd);
    log_device_summary("device_removed", &device, reason);
    devices[index] = devices[device_count - 1];
    --device_count;
}

static bool node_exists(const char *path) {
    return access(path, F_OK) == 0;
}

static double retry_time(const char *path) {
    for (size_t i = 0; i < retry_count; ++i)
        if (strcmp(retries[i].path, path) == 0) return retries[i].retry_at;
    return 0.0;
}

static void set_retry(const char *path, double now) {
    for (size_t i = 0; i < retry_count; ++i) {
        if (strcmp(retries[i].path, path) == 0) {
            retries[i].retry_at = now + RETRY_INTERVAL;
            return;
        }
    }
    if (retry_count < MAX_DEVICES) {
        snprintf(retries[retry_count].path, sizeof(retries[retry_count].path), "%s", path);
        retries[retry_count++].retry_at = now + RETRY_INTERVAL;
    }
}

static void log_open_error(const char *path, int error) {
    log_prefix("device_open_error");
    printf(",\"path\":"); json_string(path);
    printf(",\"errno\":%d,\"error\":", error);
    json_string(strerror(error));
    puts("}");
    fflush(stdout);
}

static void discover_devices(double now) {
    DIR *dir = opendir(INPUT_DIR);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) != 0) continue;
        char path[256];
        if (snprintf(path, sizeof(path), "%s/%s", INPUT_DIR, entry->d_name) >= (int)sizeof(path))
            continue;
        bool known = false;
        for (size_t i = 0; i < device_count; ++i)
            if (strcmp(devices[i].path, path) == 0) known = true;
        if (known || retry_time(path) > now || device_count >= MAX_DEVICES) continue;

        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) {
            set_retry(path, now);
            log_open_error(path, errno);
            continue;
        }
        if (!is_keyboard(fd)) { close(fd); continue; }
        struct device *device = &devices[device_count];
        memset(device, 0, sizeof(*device));
        device->fd = fd;
        snprintf(device->path, sizeof(device->path), "%s", path);
        if (ioctl(fd, EVIOCGNAME(sizeof(device->name)), device->name) < 0)
            snprintf(device->name, sizeof(device->name), "unknown");
        device->last_report = now;
        sync_pressed_state(device, now);
        ++device_count;
        log_prefix("device_added");
        printf(",\"path\":"); json_string(device->path);
        printf(",\"name\":"); json_string(device->name);
        log_held_fields(device);
        puts("}");
        fflush(stdout);
    }
    closedir(dir);

    for (size_t i = 0; i < retry_count;) {
        if (!node_exists(retries[i].path)) {
            retries[i] = retries[retry_count - 1];
            --retry_count;
        } else ++i;
    }
}

static bool process_events(struct device *device) {
    struct input_event events[64];
    for (;;) {
        ssize_t bytes = read(device->fd, events, sizeof(events));
        if (bytes < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return true;
            ++device->read_errors;
            return false;
        }
        if (bytes == 0) return false;
        size_t count = (size_t)bytes / sizeof(events[0]);
        for (size_t i = 0; i < count; ++i) {
            struct input_event *event = &events[i];
            if (event->type == EV_KEY && event->code <= KEY_MAX) {
                int code = event->code;
                if (event->value == 0) {
                    ++device->key_up;
                    if (device->pressed[code]) {
                        double duration = monotonic_seconds() - device->pressed_since[code];
                        if (duration >= LONG_HOLD_SECONDS) {
                            ++device->long_hold_warnings;
                            log_prefix("long_key_hold_ended");
                            printf(",\"path\":"); json_string(device->path);
                            printf(",\"name\":"); json_string(device->name);
                            printf(",\"held_seconds\":%.1f", duration);
                            log_held_fields(device);
                            puts("}"); fflush(stdout);
                        }
                    }
                    device->pressed[code] = false;
                    device->warned[code] = false;
                } else if (event->value == 1) {
                    ++device->key_down;
                    if (!device->pressed[code]) {
                        device->pressed[code] = true;
                        device->pressed_since[code] = monotonic_seconds();
                    }
                } else if (event->value == 2) ++device->key_repeat;
            } else if (event->type == EV_SYN && event->code == SYN_DROPPED) {
                ++device->syn_dropped;
                sync_pressed_state(device, monotonic_seconds());
            }
        }
    }
}

static void report_holds(struct device *device, double now) {
    for (int code = 0; code <= KEY_MAX; ++code) {
        if (device->pressed[code] && !device->warned[code] &&
            now - device->pressed_since[code] >= LONG_HOLD_SECONDS) {
            device->warned[code] = true;
            ++device->long_hold_warnings;
            log_prefix("long_key_hold");
            printf(",\"path\":"); json_string(device->path);
            printf(",\"name\":"); json_string(device->name);
            printf(",\"held_seconds\":%.1f", now - device->pressed_since[code]);
            log_held_fields(device);
            puts("}"); fflush(stdout);
        }
    }
}

static void on_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

int main(void) {
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    log_prefix("daemon_started");
    printf(",\"input_dir\":\"%s\",\"detail\":\"key identities are held in memory only and are not logged\"}\n", INPUT_DIR);
    fflush(stdout);
    double next_scan = 0.0;
    while (!stopping) {
        double now = monotonic_seconds();
        if (now >= next_scan) {
            for (size_t i = 0; i < device_count;) {
                if (!node_exists(devices[i].path)) close_device(i, "device_node_disappeared");
                else ++i;
            }
            discover_devices(now);
            next_scan = now + 2.0;
        }
        for (size_t i = 0; i < device_count;) {
            struct device *device = &devices[i];
            if (!process_events(device)) {
                close_device(i, "read_error");
                continue;
            }
            now = monotonic_seconds();
            report_holds(device, now);
            if (now - device->last_report >= REPORT_INTERVAL) {
                log_device_summary("device_summary", device, NULL);
                device->last_report = now;
            }
            ++i;
        }
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 500000000};
        nanosleep(&pause, NULL);
    }
    while (device_count) close_device(device_count - 1, "daemon_stopping");
    log_prefix("daemon_stopped");
    puts("}");
    return 0;
}
