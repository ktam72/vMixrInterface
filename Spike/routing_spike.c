// Spike: per-device IOProc mixer architecture verification.
//
// Verifies that the mixer engine can be built on one AudioDevice IOProc per
// device (the pattern proven by vMixr/driver/loopback-test/loopback_test.c),
// instead of:
//   - 'ahal' AudioUnit output, which coreaudiod paces at the system rate
//     (44.1kHz) while the device runs at 48kHz (rate mismatch), and
//   - AVAudioEngine capture, which can only reach the default input device.
//
// Key properties under test:
//   (1) one IOProc per device, called at the DEVICE's native sample rate,
//   (2) a single callback sees both inInputData and inOutputData,
//   (3) cross-device routing: device B's output reads device A's captured
//       input (the core operation a mixer needs),
//   (4) real devices (default output/input) work with the same code path.
//
// Topology (indices 0..3 = vMixr 1..4, 4 = default output, 5 = default input):
//   0 vMixr 1: output <- 440Hz tone,        input -> ring0
//   1 vMixr 2: output <- ring0 (cross),     input -> ring1
//   2 vMixr 3: output <- silence,           input -> ring2
//   3 vMixr 4: output <- silence,           input -> ring3
//   4 default output: output <- ring0*0.05, input -> ring4 (if any)
//   5 default input : (no output)           input -> ring5
//
// Expectations:
//   ring0 = tone (vMixr 1 self-loopback, amplitude 0.5)
//   ring1 = tone (cross-route from vMixr 1's input, amplitude 0.5)
//   ring2/3 = silence
//   rates are reported per device.

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define kMaxDev 8
#define kRingFrames (48000 * 4)     // 4 s at 48 kHz
#define kToneFrames 48000           // 1 s at 48 kHz
#define kToneFreq 440.0
#define kToneAmp 0.5f
#define kRunSeconds 3

typedef struct {
    AudioObjectID dev;
    AudioDeviceIOProcID ioproc;
    int index;
    char name[80];
    char uid[48];
    int hasOutput;
    int hasInput;
    long outRead;                   // read cursor for this device's output source
    double inPeak;
    long callbacks;
    long outFrames;
    long inFrames;
    uint64_t t0, t1;                // first/last callback host time
} Dev;

static Dev gDev[kMaxDev];
static int gCount = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static float gTone[kToneFrames * 2];
static float* gRing[kMaxDev];
static long gWrite[kMaxDev];

// --- helpers ---------------------------------------------------------------

static double HostSeconds(uint64_t t0, uint64_t t1) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)(t1 - t0) * (double)tb.numer / (double)tb.denom / 1e9;
}

// The HAL hands kAudioDevicePropertyDeviceUID back as a CFStringRef pointer
// (8 bytes), not a C string: read the reference, then convert it.
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
        if (ref != NULL) {
            char buf[128];
            int match = CFStringGetCString(ref, buf, sizeof(buf), kCFStringEncodingUTF8) && strcmp(buf, uid) == 0;
            CFRelease(ref);
            if (match) { *out = ids[i]; return 1; }
        }
    }
    return 0;
}

static void GetName(AudioObjectID dev, char* buf, size_t n) {
    AudioObjectPropertyAddress a = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef ref = NULL;
    UInt32 size = sizeof(ref);
    if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &ref) == noErr && ref) {
        CFStringGetCString(ref, buf, n, kCFStringEncodingUTF8);
        CFRelease(ref);
    } else {
        snprintf(buf, n, "dev %u", (unsigned)dev);
    }
}

static AudioObjectID DefaultDevice(int input) {
    AudioObjectID dev = 0;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress a = {
        input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev);
    return dev;
}

static void Streams(AudioObjectID dev, int* hasIn, int* hasOut) {
    AudioObjectPropertyAddress a = { kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    *hasOut = (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) == noErr && size > 0);
    a.mScope = kAudioDevicePropertyScopeInput;
    size = 0;
    *hasIn = (AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) == noErr && size > 0);
}

// --- IOProc ----------------------------------------------------------------

static OSStatus IOProc(AudioObjectID inDevice, const AudioTimeStamp* inNow,
                       const AudioBufferList* inInputData,
                       const AudioTimeStamp* inInputTime,
                       AudioBufferList* inOutputData,
                       const AudioTimeStamp* inOutputTime,
                       void* inClientData) {
    Dev* d = (Dev*)inClientData;
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    if (!d) return noErr;

    uint64_t now = mach_absolute_time();
    pthread_mutex_lock(&gLock);
    if (d->t0 == 0) d->t0 = now;
    d->t1 = now;

    // ---- output ----
    if (inOutputData && d->hasOutput && inOutputData->mNumberBuffers > 0) {
        AudioBuffer* ob = &inOutputData->mBuffers[0];
        int ch = ob->mNumberChannels ? (int)ob->mNumberChannels : 2;
        float* dst = (float*)ob->mData;
        long n = (long)(ob->mDataByteSize / (sizeof(float) * ch));
        d->callbacks++;
        d->outFrames += n;

        long r = d->outRead;
        for (long f = 0; f < n; f++) {
            float l = 0.0f, rr = 0.0f;
            if (d->index == 0) {
                long p = (r + f) % kToneFrames;
                l = gTone[p * 2 + 0];
                rr = gTone[p * 2 + 1];
            } else if (d->index == 1 || d->index == 4) {
                // cross-route: read vMixr 1's captured input (ring0)
                float gain = (d->index == 4) ? 0.05f : 1.0f;
                if (r + f < gWrite[0]) {
                    long p = (r + f) % kRingFrames;
                    l = gRing[0][p * 2 + 0] * gain;
                    rr = gRing[0][p * 2 + 1] * gain;
                }
            }
            for (int c = 0; c < ch; c++) {
                dst[f * ch + c] = (c == 0) ? l : ((c == 1) ? rr : 0.0f);
            }
        }
        if (d->index == 0) d->outRead = (r + n) % kToneFrames;
        else d->outRead = r + n;
    }

    // ---- input ----
    if (inInputData && d->hasInput && inInputData->mNumberBuffers > 0) {
        const AudioBuffer* ib = &inInputData->mBuffers[0];
        int ch = ib->mNumberChannels ? (int)ib->mNumberChannels : 1;
        const float* src = (const float*)ib->mData;
        long n = (long)(ib->mDataByteSize / (sizeof(float) * ch));
        d->inFrames += n;
        float* ring = gRing[d->index];
        if (ring) {
            long w = gWrite[d->index];
            for (long f = 0; f < n; f++) {
                float l = src[f * ch + 0];
                float rr = (ch > 1) ? src[f * ch + 1] : l;
                long p = (w + f) % kRingFrames;
                ring[p * 2 + 0] = l;
                ring[p * 2 + 1] = rr;
                if (fabs(l) > d->inPeak) d->inPeak = fabs(l);
            }
            gWrite[d->index] = w + n;
        }
    }
    pthread_mutex_unlock(&gLock);
    return noErr;
}

// --- setup / report --------------------------------------------------------

static int AddDevice(const char* uid, int index) {
    AudioObjectID dev = 0;
    if (uid) {
        if (!FindByUID(uid, &dev)) { printf("not found: %s\n", uid); return 0; }
    } else {
        dev = DefaultDevice(index == 5 ? 1 : 0);
        if (!dev) { printf("no default device for index %d\n", index); return 0; }
    }
    Dev* d = &gDev[gCount];
    memset(d, 0, sizeof(*d));
    d->dev = dev;
    d->index = index;
    snprintf(d->uid, sizeof(d->uid), "%s", uid ? uid : "(default)");
    GetName(dev, d->name, sizeof(d->name));
    Streams(dev, &d->hasInput, &d->hasOutput);
    gRing[index] = (float*)calloc(kRingFrames * 2, sizeof(float));
    gWrite[index] = 0;
    printf("[%d] %-28s obj=%-4u uid=%-12s in=%d out=%d\n",
           index, d->name, (unsigned)dev, d->uid, d->hasInput, d->hasOutput);
    gCount++;
    return 1;
}

static void RingStats(int idx, const char* label) {
    long w = gWrite[idx];
    long n = w < 48000 ? 0 : 48000;          // analyse the last second
    if (n == 0) { printf("%-14s: no data (write=%ld)\n", label, w); return; }
    long start = w - n;
    double sum = 0; float peak = 0;
    for (long i = start; i < w; i++) {
        float v = gRing[idx][(i % kRingFrames) * 2 + 0];
        sum += (double)v * v;
        if (fabsf(v) > peak) peak = fabsf(v);
    }
    printf("%-14s: RMS=%.4f peak=%.4f (frames=%ld)\n", label, sqrt(sum / n), peak, w);
}

int main(void) {
    for (int i = 0; i < kToneFrames; i++) {
        double ph = 2.0 * M_PI * kToneFreq * (double)i / 48000.0;
        gTone[i * 2 + 0] = kToneAmp * (float)sin(ph);
        gTone[i * 2 + 1] = kToneAmp * (float)sin(ph);
    }

    printf("=== devices ===\n");
    AddDevice("vMixr1_UID", 0);
    AddDevice("vMixr2_UID", 1);
    AddDevice("vMixr3_UID", 2);
    AddDevice("vMixr4_UID", 3);
    AddDevice("BuiltInSpeakerDevice", 4);          // real output (speakers)
    AddDevice("BuiltInMicrophoneDevice", 5);       // real input (mic)

    // Deduplicate the default output/input if they coincide with a vMixr device
    // or each other: two IOProcs on one device would be started twice.
    for (int i = 0; i < gCount; i++) {
        for (int j = i + 1; j < gCount; j++) {
            if (gDev[i].dev == gDev[j].dev) {
                printf("note: [%d] and [%d] are the same device (%s); disabling [%d]\n",
                       i, j, gDev[i].name, j);
                gDev[j].hasOutput = 0;
                gDev[j].hasInput = 0;
            }
        }
    }

    printf("\n=== start ===\n");
    int started = 0;
    for (int i = 0; i < gCount; i++) {
        Dev* d = &gDev[i];
        if (!d->hasInput && !d->hasOutput) continue;
        OSStatus st = AudioDeviceCreateIOProcID(d->dev, IOProc, d, &d->ioproc);
        if (st != noErr) { printf("[%d] CreateIOProcID failed st=%d\n", i, (int)st); continue; }
        st = AudioDeviceStart(d->dev, d->ioproc);
        if (st != noErr) { printf("[%d] Start failed st=%d\n", i, (int)st); AudioDeviceDestroyIOProcID(d->dev, d->ioproc); d->ioproc = NULL; continue; }
        printf("[%d] %s started\n", i, d->name);
        started++;
    }
    printf("running %d s ...\n", kRunSeconds);
    for (int i = 0; i < kRunSeconds * 2; i++) usleep(500000);

    for (int i = 0; i < gCount; i++) {
        Dev* d = &gDev[i];
        if (d->ioproc) { AudioDeviceStop(d->dev, d->ioproc); AudioDeviceDestroyIOProcID(d->dev, d->ioproc); d->ioproc = NULL; }
    }

    printf("\n=== rates (device native) ===\n");
    for (int i = 0; i < gCount; i++) {
        Dev* d = &gDev[i];
        double sec = HostSeconds(d->t0, d->t1);
        long frames = d->outFrames ? d->outFrames : d->inFrames;
        double rate = sec > 0 ? (double)frames / sec : 0;
        printf("[%d] %-28s outHz=%8.1f  inHz=%8.1f  callbacks=%ld\n",
               i, d->name,
               sec > 0 ? (double)d->outFrames / sec : 0,
               sec > 0 ? (double)d->inFrames / sec : 0,
               d->callbacks);
        (void)rate;
    }

    printf("\n=== captured rings (expect ring0=tone, ring1=tone, ring2/3=silent) ===\n");
    RingStats(0, "ring0 vMixr1");
    RingStats(1, "ring1 vMixr2");
    RingStats(2, "ring2 vMixr3");
    RingStats(3, "ring3 vMixr4");
    RingStats(5, "ring5 defaultIn");
    printf("[0] vMixr1 inPeak=%.4f (tone)  [1] vMixr2 inPeak=%.4f (cross)\n", gDev[0].inPeak, gDev[1].inPeak);

    for (int i = 0; i < kMaxDev; i++) free(gRing[i]);
    return 0;
}
