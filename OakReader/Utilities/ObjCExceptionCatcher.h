#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches Objective-C exceptions thrown within a block.
/// Swift cannot catch NSException, so this wrapper is needed for
/// libraries like USearch that use @throw on failure.
@interface ObjCExceptionCatcher : NSObject

/// Runs the block and returns YES on success.
/// If an NSException is thrown, catches it, passes it to the error handler, and returns NO.
+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block
               error:(void (NS_NOESCAPE ^ _Nullable)(NSException *exception))errorHandler
    NS_SWIFT_NAME(perform(_:error:));

@end

NS_ASSUME_NONNULL_END
