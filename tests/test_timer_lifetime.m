#import <AppKit/AppKit.h>
#import "../Packages/KYASleepWakeTimer/Sources/KYASleepWakeTimer/KYASleepWakeTimer.m"

// Exercise production timer lifetime/callback code while replacing only the
// subprocess launch. No real caffeinate process or power assertion is created.
@interface KYARegressionTask : NSTask
@property (nonatomic) BOOL fakeRunning;
@property (nonatomic) BOOL terminated;
@property (copy, nullable) void (^terminationHandler)(NSTask *);
@end

@implementation KYARegressionTask
@synthesize terminationHandler = _fakeTerminationHandler;
- (BOOL)isRunning { return self.fakeRunning; }
- (void)terminate { self.fakeRunning = NO; self.terminated = YES; }
@end

@interface KYARegressionTimer : KYASleepWakeTimer
@property (nonatomic) KYARegressionTask *latestTask;
@end

@implementation KYARegressionTimer
- (void)spawnCaffeinateTaskForTimeInterval:(NSTimeInterval)timeInterval
{
    KYARegressionTask *task = [KYARegressionTask new];
    task.fakeRunning = YES;
    task.terminationHandler = ^(NSTask *finished) {};
    self.latestTask = task;
    self.caffeinateTask = task;
}
@end

@interface KYARegressionProbe : NSObject
@property (nonatomic, weak) KYASleepWakeTimer *timer;
@end
@implementation KYARegressionProbe
@end

@interface KYARegressionDelegate : NSObject <KYASleepWakeTimerDelegate>
@property (nonatomic) NSUInteger deactivations;
@end

@implementation KYARegressionDelegate
- (void)sleepWakeTimerDidDeactivate:(KYASleepWakeTimer *)timer
{
    NSCAssert(!timer.isScheduled, @"The delegate received a still-active timer.");
    self.deactivations++;
}
@end

static void KYADrainMainQueue(void)
{
    __block BOOL drained = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while(!drained && deadline.timeIntervalSinceNow > 0)
    {
        @autoreleasepool
        {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    NSCAssert(drained, @"The main queue did not drain.");
}

int main(void)
{
    @autoreleasepool
    {
        for(NSUInteger iteration = 0; iteration < 500; iteration++)
        {
            __weak KYASleepWakeTimer *releasedTimer = nil;
            @autoreleasepool
            {
                KYASleepWakeTimer *timer = [KYASleepWakeTimer new];
                releasedTimer = timer;
            }
            NSCAssert(releasedTimer == nil, @"A fresh timer survived release.");
        }
        KYADrainMainQueue();
        puts("PASS repeated fresh timer release and runloop drain");

        KYARegressionTask *releasedTask = nil;
        __weak KYASleepWakeTimer *releasedTimer = nil;
        @autoreleasepool
        {
            KYARegressionTimer *timer = [KYARegressionTimer new];
            [timer scheduleWithTimeInterval:0 completion:nil];
            releasedTask = timer.latestTask;
            releasedTimer = timer;
            NSCAssert(timer.isScheduled, @"The mock task was not scheduled.");
        }
        NSCAssert(releasedTimer == nil, @"A scheduled timer survived release.");
        NSCAssert(releasedTask.terminated && !releasedTask.isRunning, @"Release did not stop the task.");
        NSCAssert(releasedTask.terminationHandler == nil, @"Release left a task callback attached.");
        KYADrainMainQueue();
        puts("PASS scheduled timer release stops task without queuing callbacks");

        const NSUInteger iterations = 500;
        KYARegressionDelegate *delegate = [KYARegressionDelegate new];
        NSMutableArray<KYARegressionProbe *> *probes = [NSMutableArray new];
        __block NSUInteger completions = 0;
        for(NSUInteger iteration = 0; iteration < iterations; iteration++)
        {
            @autoreleasepool
            {
                KYARegressionTimer *timer = [KYARegressionTimer new];
                timer.delegate = delegate;
                KYARegressionProbe *probe = [KYARegressionProbe new];
                probe.timer = timer;
                [probes addObject:probe];
                [timer scheduleWithTimeInterval:1 completion:^(BOOL cancelled) {
                    NSCAssert(cancelled, @"Explicit invalidation was not reported as cancellation.");
                    completions++;
                }];
                [timer invalidate];
                NSCAssert(!timer.isScheduled && timer.fireDate == nil, @"Invalidate did not reset the timer.");
                NSCAssert(timer.latestTask.terminated, @"Invalidate did not stop the task.");
            }
        }
        KYADrainMainQueue();
        NSCAssert(delegate.deactivations == iterations, @"Expected one delegate callback per invalidation.");
        NSCAssert(completions == iterations, @"Expected one completion per invalidation.");
        for(KYARegressionProbe *probe in probes)
        {
            NSCAssert(probe.timer == nil, @"An invalidated timer remained retained after callbacks drained.");
        }
        KYADrainMainQueue();
        NSCAssert(delegate.deactivations == iterations && completions == iterations, @"Deallocation queued extra callbacks.");
        puts("PASS repeated invalidate/release drains callbacks and releases weak timers");
    }
    return 0;
}
