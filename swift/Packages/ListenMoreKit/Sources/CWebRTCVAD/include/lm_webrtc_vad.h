#ifndef LM_WEBRTC_VAD_H_
#define LM_WEBRTC_VAD_H_

#include <stddef.h>
#include <stdint.h>

/* Thin wrapper over the WebRTC VAD vendored from py-webrtcvad (the same C code the Python core uses
 * through webrtcvad-wheels), so the Swift and Python local layers classify identical frames identically.
 * The opaque handle keeps WebRTC's own include layout out of the Swift module. */

typedef struct LMWebRtcVad LMWebRtcVad;

/* Returns NULL on allocation or init failure. */
LMWebRtcVad *lm_vad_create(int mode);
void lm_vad_free(LMWebRtcVad *vad);
/* 0 on success, -1 for an invalid mode (valid: 0...3). */
int lm_vad_set_mode(LMWebRtcVad *vad, int mode);
/* 1 = speech, 0 = non-speech, -1 = error (bad rate/length). */
int lm_vad_process(LMWebRtcVad *vad, int sample_rate, const int16_t *frame, size_t frame_length);
/* 1 if WebRTC accepts this rate and frame length (8/16/32/48 kHz; 10, 20 or 30 ms). */
int lm_vad_valid_rate_and_frame_length(int sample_rate, size_t frame_length);

#endif
