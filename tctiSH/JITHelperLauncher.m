//
//  JITHelperLauncher.m
//  Launches the out-of-process JIT helper extension.
//
//  Copyright © 2026 Ara Adkins.
//

#import "JITHelperLauncher.h"

#import <os/log.h>

/// Matches `Log.jit` on the Swift side, so one filter catches both.
static os_log_t JITHelperLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("io.ara.tctish.jit", "jit");
    });
    return log;
}

/// Error domain for launch failures that aren't NSExtension's own.
static NSString *const JITHelperLauncherErrorDomain = @"io.ara.tctiSH.JITHelperLauncher";

typedef NS_ENUM(NSInteger, JITHelperLauncherError) {
    JITHelperLauncherErrorUnavailable = 1,  ///< NSExtension isn't there any more.
    JITHelperLauncherErrorNoExtension = 2,  ///< The helper couldn't be resolved.
    JITHelperLauncherErrorTimedOut = 3,     ///< It never came back.
};

/// The private `NSExtension` API, split in two because the class methods are
/// reached by casting the Class object.
@protocol JITNSExtensionClass <NSObject>
- (id _Nullable)extensionWithIdentifier:(NSString *)identifier
                                  error:(NSError *_Nullable *_Nullable)error;
@end

@protocol JITNSExtensionInstance <NSObject>
- (void)beginExtensionRequestWithInputItems:(NSArray *_Nullable)items
                                 completion:(void (^)(NSUUID *requestIdentifier))completion;
- (int)pidForRequestIdentifier:(NSUUID *)requestIdentifier;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *requestIdentifier,
                                            NSArray *extensionItems))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *requestIdentifier))block;
@end

@implementation JITHelperLauncher

/// Bundle identifier of the helper, derived from ours so the two can't drift.
+ (NSString *)helperBundleIdentifier {
    NSString *hostIdentifier = NSBundle.mainBundle.bundleIdentifier;
    return [hostIdentifier stringByAppendingString:@".JITHelper"];
}

+ (void)launchWithPayload:(NSDictionary *_Nullable)payload
                  timeout:(NSTimeInterval)timeout
               completion:(void (^)(pid_t, NSArray *_Nullable, NSError *_Nullable))completion {

    // Only ever call the caller back once, whichever of the completion, the
    // interruption or the timeout gets there first.
    __block BOOL finished = NO;
    NSLock *lock = [[NSLock alloc] init];

    // The extension has to outlive this scope, and the obvious way to arrange
    // that -- capturing it in the blocks below -- is a cycle, because those
    // blocks are stored *on* the extension. That leaks one per launch. So it is
    // held here instead and let go of when the request ends, which always
    // happens: the timeout sees to that even if nothing else does.
    __block id<JITNSExtensionInstance> liveExtension = nil;

    void (^finish)(pid_t, NSArray *, NSError *) = ^(pid_t pid, NSArray *items, NSError *error) {
        [lock lock];
        BOOL alreadyFinished = finished;
        finished = YES;
        [lock unlock];

        if (!alreadyFinished) {
            liveExtension = nil;
            completion(pid, items, error);
        }
    };

    Class extensionClass = NSClassFromString(@"NSExtension");
    if (extensionClass == nil) {
        finish(0, nil,
               [NSError
                   errorWithDomain:JITHelperLauncherErrorDomain
                              code:JITHelperLauncherErrorUnavailable
                          userInfo:@{
                              NSLocalizedDescriptionKey: @"NSExtension is unavailable on this OS"
                          }]);
        return;
    }

    NSString *identifier = [self helperBundleIdentifier];
    NSError *resolveError = nil;
    id<JITNSExtensionInstance> extension =
        [(id<JITNSExtensionClass>)extensionClass extensionWithIdentifier:identifier
                                                                   error:&resolveError];

    if (extension == nil) {
        NSError *error = resolveError
                             ?: [NSError errorWithDomain:JITHelperLauncherErrorDomain
                                                    code:JITHelperLauncherErrorNoExtension
                                                userInfo:@{
                                                    NSLocalizedDescriptionKey:
                                                        @"could not resolve the helper extension"
                                                }];
        finish(0, nil, error);
        return;
    }

    liveExtension = extension;

    __block pid_t helperPid = 0;

    [extension setRequestCompletionBlock:^(NSUUID *requestIdentifier, NSArray *extensionItems) {
        finish(helperPid, extensionItems, nil);
    }];

    [extension setRequestInterruptionBlock:^(NSUUID *requestIdentifier) {
        finish(helperPid, nil,
               [NSError
                   errorWithDomain:JITHelperLauncherErrorDomain
                              code:JITHelperLauncherErrorNoExtension
                          userInfo:@{ NSLocalizedDescriptionKey: @"the helper was interrupted" }]);
    }];

    NSArray *inputItems = @[];
    if (payload != nil) {
        NSExtensionItem *item = [[NSExtensionItem alloc] init];
        item.userInfo = payload;
        inputItems = @[item];
    }

    [extension
        beginExtensionRequestWithInputItems:inputItems
                                 completion:^(NSUUID *requestIdentifier) {
                                     helperPid =
                                         [extension pidForRequestIdentifier:requestIdentifier];
                                     os_log(JITHelperLog(),
                                            "host: request %{public}@ running as pid %{public}d",
                                            requestIdentifier.UUIDString, helperPid);
                                 }];

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            finish(
                helperPid, nil,
                [NSError
                    errorWithDomain:JITHelperLauncherErrorDomain
                               code:JITHelperLauncherErrorTimedOut
                           userInfo:@{ NSLocalizedDescriptionKey: @"the helper did not respond" }]);
        });
}

@end
