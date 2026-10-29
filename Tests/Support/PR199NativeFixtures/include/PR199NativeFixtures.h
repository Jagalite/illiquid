#import <Foundation/Foundation.h>
// NSObject return deliberately avoids automatic NSURL-to-Swift-URL bridging.
FOUNDATION_EXPORT NSObject * _Nullable PR199CreatePath(NSString * _Nonnull path, BOOL directory);
FOUNDATION_EXPORT NSObject * _Nullable PR199CreateReference(NSString * _Nonnull path, BOOL directory);
