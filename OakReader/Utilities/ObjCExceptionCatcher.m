#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)performBlock:(void (NS_NOESCAPE ^)(void))block
               error:(void (NS_NOESCAPE ^ _Nullable)(NSException *exception))errorHandler {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (errorHandler) {
            errorHandler(exception);
        }
        return NO;
    }
}

@end
