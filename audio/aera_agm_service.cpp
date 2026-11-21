/*
 * Copyright (C) 2026 AERA Recovery Project contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Init-owned host for Houji's installed primary HAL and its PAL/AGM services.
 */
#include <android/log.h>
#include <dlfcn.h>
#include <hardware/hardware.h>
#include <hidl/HidlTransportSupport.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

namespace {
constexpr char kTag[] = "AERAAudio";
constexpr char kPrimaryHal[] =
    "/system/aera-audio-vendor/lib64/hw/audio.primary.pineapple.so";
constexpr char kReadyProperty[] = "vendor.houji.audio.hal.ready";
constexpr char kAudioHardwareInterface[] = "audio_hw_if";

struct AudioModule {
  hw_module_t common;
};

void Log(int priority, const char* message) {
  __android_log_write(priority, kTag, message);
  std::fprintf(stderr, "%s\n", message);
}
}  // namespace

int main(int argc, char** argv) {
  if (argc != 2 || std::strcmp(argv[1], "--houji-stock-audio") != 0 ||
      getuid() != 0) {
    Log(ANDROID_LOG_ERROR, "The Houji stock-audio mode requires root.");
    return 64;
  }
  if (__system_property_set(kReadyProperty, "0") != 0) {
    Log(ANDROID_LOG_ERROR, "Could not clear Houji HAL readiness.");
    return 70;
  }
  if (access(kPrimaryHal, R_OK) != 0) {
    Log(ANDROID_LOG_ERROR, "The installed Houji primary HAL is unavailable.");
    return 66;
  }

  android::hardware::configureRpcThreadpool(8, true);
  void* library = dlopen(kPrimaryHal, RTLD_NOW | RTLD_GLOBAL);
  if (!library) {
    __android_log_print(ANDROID_LOG_ERROR, kTag,
                        "Primary audio HAL load failed: %s", dlerror());
    return 67;
  }

  dlerror();
  auto* module = static_cast<AudioModule*>(
      dlsym(library, HAL_MODULE_INFO_SYM_AS_STR));
  const char* symbol_error = dlerror();
  if (!module || symbol_error || !module->common.methods ||
      !module->common.methods->open) {
    __android_log_print(ANDROID_LOG_ERROR, kTag,
                        "Primary audio HAL entry point is unavailable: %s",
                        symbol_error ? symbol_error : "invalid HAL module");
    return 68;
  }

  hw_device_t* raw_device = nullptr;
  const int status = module->common.methods->open(
      &module->common, kAudioHardwareInterface, &raw_device);
  if (status != 0 || !raw_device) {
    __android_log_print(ANDROID_LOG_ERROR, kTag,
                        "Primary audio HAL initialization failed: %d", status);
    return 69;
  }
  if (__system_property_set(kReadyProperty, "1") != 0) {
    __system_property_set(kReadyProperty, "0");
    Log(ANDROID_LOG_ERROR, "Could not publish Houji HAL readiness.");
    return 70;
  }

  // Registered HIDL objects retain HAL callbacks until this process exits.
  Log(ANDROID_LOG_INFO, "Houji primary audio HAL opened.");
  android::hardware::joinRpcThreadpool();
  __system_property_set(kReadyProperty, "0");
  Log(ANDROID_LOG_ERROR, "Audio HIDL thread pool exited unexpectedly.");
  return 70;
}
