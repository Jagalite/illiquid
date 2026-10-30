#import "PR170NativeFixtures.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
NSObject * _Nullable PR170CreatePath(NSString *path, BOOL directory) {
    return [[NSURL alloc] initFileURLWithPath:path isDirectory:directory];
}
BOOL PR170CanResolve(NSObject *object) {
    // Keep unexpected native types fatal, never classify them as unresolved fixtures.
    if (![object isKindOfClass:[NSURL class]]) abort();
    NSURL *url = (NSURL *)object;
    CFURLRef reference = (__bridge CFURLRef)url;
    if (!CFURLIsFileReferenceURL(reference)) return YES;
    CFURLRef resolved = CFURLCreateFilePathURL(kCFAllocatorDefault, reference, NULL);
    if (!resolved) return NO;
    CFRelease(resolved);
    return YES;
}
