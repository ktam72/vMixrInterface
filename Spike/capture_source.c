// Reads a vMixr device's input for N seconds and writes a float32 stereo WAV.
// Used to isolate whether the glitches come from the driver's cross-client
// loopback (this tool reads while tone_source writes) or from the app engine.
//
// usage: capture_source [uid] [seconds] [out.wav]

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define kMaxFrames (48000 * 20)
static float gBuf[kMaxFrames * 2];
static long gFill = 0;

static OSStatus IOProc(AudioObjectID d, const AudioTimeStamp* n, const AudioBufferList* in,
                       const AudioTimeStamp* it, AudioBufferList* out, const AudioTimeStamp* ot, void* c) {
    (void)d; (void)n; (void)it; (void)out; (void)ot; (void)c;
    if (!in || in->mNumberBuffers < 1) return noErr;
    const AudioBuffer* b = &in->mBuffers[0];
    int ch = b->mNumberChannels ? (int)b->mNumberChannels : 1;
    const float* p = (const float*)b->mData;
    if (!p) return noErr;
    long frames = (long)(b->mDataByteSize / (sizeof(float) * ch));
    for (long f = 0; f < frames; f++) {
        if (gFill < kMaxFrames) {
            gBuf[gFill * 2 + 0] = p[f * ch + 0];
            gBuf[gFill * 2 + 1] = (ch > 1) ? p[f * ch + 1] : p[f * ch + 0];
            gFill++;
        }
    }
    return noErr;
}

static int FindByUID(const char* uid, AudioObjectID* out) {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr) return 0;
    AudioObjectID ids[128];
    if (size / sizeof(AudioObjectID) > 128) size = 128 * sizeof(AudioObjectID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) != noErr) return 0;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        AudioObjectPropertyAddress na = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, ids[i] };
        CFStringRef ref = NULL;
        UInt32 nsz = sizeof(ref);
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &nsz, &ref) != noErr) continue;
        if (ref) {
            char buf[128];
            int m = CFStringGetCString(ref, buf, sizeof(buf), kCFStringEncodingUTF8) && strcmp(buf, uid) == 0;
            CFRelease(ref);
            if (m) { *out = ids[i]; return 1; }
        }
    }
    return 0;
}

static void WriteWAV(const char* path, const float* frames, long n, double rate) {
    FILE* fp = fopen(path, "wb");
    if (!fp) return;
    int ch = 2;
    unsigned sr = (unsigned)(rate + 0.5);
    unsigned dataBytes = (unsigned)(n * ch * 4);
    unsigned riff = 36 + dataBytes;
    unsigned short one = 1, two = 2, fmt = 3, bits = 32, bpf = (unsigned short)(ch * 4);
    unsigned short ba = (unsigned short)(8);
    fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp); fwrite("WAVE", 1, 4, fp);
    fwrite("fmt ", 1, 4, fp); unsigned sixteen = 16; fwrite(&sixteen, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp); fwrite(&two, 2, 1, fp); fwrite(&sr, 4, 1, fp);
    unsigned br = sr * ch * 4; fwrite(&br, 4, 1, fp); fwrite(&bpf, 2, 1, fp); fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp); fwrite(&dataBytes, 4, 1, fp);
    (void)one; (void)ba;
    fwrite(frames, 4, (size_t)n * ch, fp);
    fclose(fp);
}

int main(int argc, char** argv) {
    const char* uid = argc > 1 ? argv[1] : "vMixr1_UID";
    int seconds = argc > 2 ? atoi(argv[2]) : 6;
    const char* out = argc > 3 ? argv[3] : "/tmp/cap_src.wav";
    AudioObjectID dev = 0;
    if (!FindByUID(uid, &dev)) { printf("not found: %s\n", uid); return 1; }

    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(dev, IOProc, NULL, &id) != noErr) { printf("create failed\n"); return 1; }
    if (AudioDeviceStart(dev, id) != noErr) { printf("start failed\n"); return 1; }
    printf("capturing %s for %d s\n", uid, seconds);
    for (int i = 0; i < seconds * 2; i++) usleep(500000);
    AudioDeviceStop(dev, id);
    AudioDeviceDestroyIOProcID(dev, id);
    WriteWAV(out, gBuf, gFill, 48000.0);
    printf("wrote %s frames=%ld\n", out, gFill);
    return 0;
}
