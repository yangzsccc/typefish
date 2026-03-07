#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Catches ObjC exceptions and converts them to NSError
BOOL ObjCTry(void (^_Nonnull block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
