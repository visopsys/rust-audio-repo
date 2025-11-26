#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*audio_callback_t)(const void* data, uint32_t length);

void set_audio_callback(audio_callback_t cb);
void start_audio_recording(void);
void stop_audio_recording(void);
void run_main_loop_for(double seconds);


#ifdef __cplusplus
}
#endif
