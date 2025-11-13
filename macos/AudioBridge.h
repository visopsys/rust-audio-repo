#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*audio_callback_t)(const void* data, uint32_t length);

// Set the callback that Swift will call with raw audio bytes
void set_audio_callback(audio_callback_t cb);

// Start/stop control exported from Swift
void start_audio_recording(void);
void stop_audio_recording(void);

#ifdef __cplusplus
}
#endif
