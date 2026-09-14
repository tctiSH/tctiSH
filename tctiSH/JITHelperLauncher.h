//
//  JITHelperLauncher.h
//  Launches the out-of-process JIT helper extension.
//
//  Copyright © 2026 Ara Adkins.
//

#ifndef JITHelperLauncher_h
#define JITHelperLauncher_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the JITHelper app extension and talks to it.
///
/// JIT enablement needs a second process as QEMU's `brk` stops every thread in
/// this one. An app extension is the only thing iOS lets an app start on demand
/// for that purpose, and starting one requires `NSExtension`, which is a
/// private API. tctiSH is only ever sideloaded, so that a cost that is fine to
/// pay.
///
/// It does, however, mean this can break on any OS update, and every failure
/// path has to fall back to TCTI cleanly.
@interface JITHelperLauncher : NSObject

/// Launches the helper, hands it `payload`, and reports what came back.
///
/// The extension request is itself a request/response channel so it doubles as
/// the IPC and no separate XPC connection is needed.
///
/// `completion` is called exactly once, on an unspecified queue.
+ (void)launchWithPayload:(NSDictionary *_Nullable)payload
                  timeout:(NSTimeInterval)timeout
               completion:(void (^)(pid_t helperPid, NSArray *_Nullable replyItems,
                                    NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* JITHelperLauncher_h */
