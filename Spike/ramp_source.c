// Writes a 440Hz tone to a vMixr device's output via one IOProc (the device's
// native rate), standing in for "another app plays into vMixr 1". Used to
// verify the vMixrInterface engine end to end: the app reads vMixr 1's input
// (the driver's loopback) and renders it to its output buses.
//
// usage: tone_source [uid] [seconds]

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static double gPhase = 0;
static double gInc;
static float gCap[48000 * 12 * 2];
static long gCapFill = 0;
static int gHist[8192];
static int gHistIn[8192];

static OSStatus IOProc(AudioObjectID d, const AudioTimeStamp* n, const AudioBufferList* in,
                       const AudioTimeStamp* it, AudioBufferList* out, const AudioTimeStamp* ot, void* c) {
    (void)d; (void)n; (void)it; (void)ot; (void)c;
    if (!out || out->mNumberBuffers < 1) return noErr;
    AudioBuffer* b = &out->mBuffers[0];
    int ch = b->mNumberChannels ? (int)b->mNumberChannels : 2;
    float* p = (float*)b->mData;
    if (!p) return noErr;
    long frames = (long)(b->mDataByteSize / (sizeof(float) * ch));
    gHist[frames < 8192 ? (int)frames : 8191]++;
    for (long f = 0; f < frames; f++) {
        float v = (float)gPhase;
        gPhase += 0.002;               /* 1000-sample sawtooth, slope 0.002 */
        if (gPhase > 1.0) gPhase -= 2.0;
        for (int c = 0; c < ch; c++) p[f * ch + c] = v;
    }
    // capture the same device's input (its own loopback) for comparison
    if (in && in->mNumberBuffers >= 1) {
        const AudioBuffer* ib = &in->mBuffers[0];
        int ich = ib->mNumberChannels ? (int)ib->mNumberChannels : 1;
        const float* ip = (const float*)ib->mData;
        if (ip) {
            long inFrames = (long)(ib->mDataByteSize / (sizeof(float) * ich));
            gHistIn[inFrames < 8192 ? (int)inFrames : 8191]++;
            for (long f = 0; f < inFrames; f++) {
                if (gCapFill < 48000 * 12) {
                    gCap[gCapFill * 2 + 0] = ip[f * ich + 0];
                    gCap[gCapFill * 2 + 1] = (ich > 1) ? ip[f * ich + 1] : ip[f * ich + 0];
                    gCapFill++;
                }
            }
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

int main(int argc, char** argv) {
    const char* uid = argc > 1 ? argv[1] : "vMixr1_UID";
    int seconds = argc > 2 ? atoi(argv[2]) : 10;
    AudioObjectID dev = 0;
    if (!FindByUID(uid, &dev)) { printf("not found: %s\n", uid); return 1; }

    double nominal = 48000;
    AudioObjectPropertyAddress ra = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 rs = sizeof(nominal);
    AudioObjectGetPropertyData(dev, &ra, 0, NULL, &rs, &nominal);
    gInc = 2.0 * M_PI * 440.0 / nominal;

    AudioDeviceIOProcID id = NULL;
    if (AudioDeviceCreateIOProcID(dev, IOProc, NULL, &id) != noErr) { printf("create failed\n"); return 1; }
    if (AudioDeviceStart(dev, id) != noErr) { printf("start failed\n"); return 1; }
    printf("tone 440Hz -> %s (%.0f Hz) for %d s\n", uid, nominal, seconds);
    fflush(stdout);
    for (int i = 0; i < seconds * 2; i++) usleep(500000);
    AudioDeviceStop(dev, id);
    AudioDeviceDestroyIOProcID(dev, id);
    FILE* fp = fopen("/tmp/ts_self.wav", "wb");
    if (fp) {
        long n = gCapFill;
        int ch = 2;
        unsigned sr = 48000, dataBytes = (unsigned)(n * ch * 4), riff = 36 + dataBytes;
        unsigned sixteen = 16;
        unsigned short fmt = 3, two = 2, bits = 32, bpf = (unsigned short)(ch * 4);
        unsigned br = sr * ch * 4;
        fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp); fwrite("WAVE", 1, 4, fp);
        fwrite("fmt ", 1, 4, fp); fwrite(&sixteen, 4, 1, fp);
        fwrite(&fmt, 2, 1, fp); fwrite(&two, 2, 1, fp); fwrite(&sr, 4, 1, fp);
        fwrite(&br, 4, 1, fp); fwrite(&bpf, 2, 1, fp); fwrite(&bits, 2, 1, fp);
        fwrite("data", 1, 4, fp); fwrite(&dataBytes, 4, 1, fp);
        fwrite(gCap, 4, (size_t)n * ch, fp);
        fclose(fp);
    }
    printf("self-capture /tmp/ts_self.wav frames=%ld\n", gCapFill);
    printf("out block-size histogram (frames:count):");
    for (int i = 0; i < 8192; i++) if (gHist[i] > 0) printf(" %d:%d", i, gHist[i]);
    printf("\n");
    printf("in  block-size histogram (frames:count):");
    for (int i = 0; i < 8192; i++) if (gHistIn[i] > 0) printf(" %d:%d", i, gHistIn[i]);
    printf("\n");
    return 0;
}
