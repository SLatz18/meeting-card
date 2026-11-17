#include "include/lm_webrtc_vad.h"

#include <limits.h>
#include <stdlib.h>

#include "webrtc/common_audio/vad/include/webrtc_vad.h"

struct LMWebRtcVad {
    VadInst *inst;
};

LMWebRtcVad *lm_vad_create(int mode) {
    LMWebRtcVad *vad = (LMWebRtcVad *)calloc(1, sizeof(LMWebRtcVad));
    if (vad == NULL) {
        return NULL;
    }
    if (WebRtcVad_Create(&vad->inst) != 0 || WebRtcVad_Init(vad->inst) != 0 || WebRtcVad_set_mode(vad->inst, mode) != 0) {
        lm_vad_free(vad);
        return NULL;
    }
    return vad;
}

void lm_vad_free(LMWebRtcVad *vad) {
    if (vad == NULL) {
        return;
    }
    if (vad->inst != NULL) {
        WebRtcVad_Free(vad->inst);
    }
    free(vad);
}

int lm_vad_set_mode(LMWebRtcVad *vad, int mode) {
    return WebRtcVad_set_mode(vad->inst, mode) == 0 ? 0 : -1;
}

int lm_vad_process(LMWebRtcVad *vad, int sample_rate, const int16_t *frame, size_t frame_length) {
    if (frame_length > INT_MAX) {
        return -1;
    }
    return WebRtcVad_Process(vad->inst, sample_rate, frame, (int)frame_length);
}

int lm_vad_valid_rate_and_frame_length(int sample_rate, size_t frame_length) {
    if (frame_length > INT_MAX) {
        return 0;
    }
    return WebRtcVad_ValidRateAndFrameLength(sample_rate, (int)frame_length) == 0 ? 1 : 0;
}
