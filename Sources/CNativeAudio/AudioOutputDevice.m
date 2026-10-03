#import <AVFoundation/AVFoundation.h>
#import "CNativeAudio.h"

CFStringRef SPSetAudioOutputDevice(void *renderer, CFStringRef deviceUID) {
    @try {
        AVSampleBufferAudioRenderer *audio = (__bridge AVSampleBufferAudioRenderer *)renderer;
        audio.audioOutputDeviceUniqueID = (__bridge NSString *)deviceUID;
        return NULL;
    } @catch (NSException *exception) {
        // Swift cannot catch Objective-C exceptions. In particular, returning
        // to the default output has a documented WebKit workaround.
        return CFStringCreateCopy(kCFAllocatorDefault,
            (__bridge CFStringRef)(exception.reason ?: @"Audio output selection failed"));
    }
}
