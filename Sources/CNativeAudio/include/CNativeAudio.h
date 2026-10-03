#include <CoreFoundation/CoreFoundation.h>

// Returns a retained error description, or NULL on success. The caller keeps
// the AVSampleBufferAudioRenderer alive throughout this synchronous call.
CFStringRef _Nullable SPSetAudioOutputDevice(void * _Nonnull renderer,
                                          CFStringRef _Nullable deviceUID) CF_RETURNS_RETAINED;
