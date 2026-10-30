#import "PR199NativeFixtures.h"
NSObject * _Nullable PR199CreatePath(NSString *path, BOOL directory) {
    return [[NSURL alloc] initFileURLWithPath:path isDirectory:directory];
}
NSObject * _Nullable PR199CreateReference(NSString *path, BOOL directory) {
    NSURL *url = [[NSURL alloc] initFileURLWithPath:path isDirectory:directory];
    return [url fileReferenceURL];
}
