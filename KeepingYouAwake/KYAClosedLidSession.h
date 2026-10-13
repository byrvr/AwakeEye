//
//  KYAClosedLidSession.h
//  KeepingYouAwake
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const KYAClosedLidSessionErrorDomain;

/// An explicitly authorized, temporary override of macOS system sleep.
/// Call this controller on the main thread. Starting a session displays the
/// native administrator dialog only for one-time helper setup. Subsequent
/// activations and deactivations use its constrained, authenticated socket.
@interface KYAClosedLidSession : NSObject

@property (nonatomic, readonly) BOOL active;

/// Set when endSession could not confirm a successful reset. A new session is
/// refused while an owned session still needs cleanup.
@property (nonatomic, readonly, nullable) NSError *lastCleanupError;

/// Takes ownership of the sleep override; cleanup restores disablesleep to 0,
/// including when it was already 1 before this session started.
/// A cancelled authentication returns NSCocoaErrorDomain / NSUserCancelledError.
- (BOOL)beginSessionWithError:(NSError * _Nullable * _Nullable)error;

/// Ends the lease. The installed helper restores normal sleep on app exit,
/// app crash, or helper restart without another password prompt.
- (void)endSession;

@end

NS_ASSUME_NONNULL_END
