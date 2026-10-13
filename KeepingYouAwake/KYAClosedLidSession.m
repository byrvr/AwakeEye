//
//  KYAClosedLidSession.m
//  KeepingYouAwake
//

#import "KYAClosedLidSession.h"
#import <AppKit/AppKit.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const KYAClosedLidSessionErrorDomain = @"KYAClosedLidSessionErrorDomain";

typedef NS_ENUM(NSInteger, KYAClosedLidSessionErrorCode) {
    KYAClosedLidSessionErrorLaunch = 1,
    KYAClosedLidSessionErrorAuthentication,
    KYAClosedLidSessionErrorWatchdog,
    KYAClosedLidSessionErrorCleanup
};

static NSError *KYASessionError(KYAClosedLidSessionErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:KYAClosedLidSessionErrorDomain
                              code:code
                          userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static NSString *KYAShellQuotedString(NSString *string)
{
    return [NSString stringWithFormat:@"'%@'", [string stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *KYAAppleScriptQuotedString(NSString *string)
{
    NSString *escaped = [string stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

/// The only interpolated values are a validated positive PID and a shell-quoted
/// process identity. No app-controlled executable, file, or command is run as
/// root. mktemp creates the acknowledgement directory as root, so the app can
/// read it but cannot replace its contents or redirect privileged writes.
static NSString *KYAPrivilegedLauncherScript(pid_t leasePID, NSString *leaseIdentity)
{
    NSCParameterAssert(leasePID > 0);
    NSCParameterAssert(leaseIdentity.length > 0);

    return [NSString stringWithFormat:
        @"PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"
         "export PATH\n"
         "LC_ALL=C\n"
         "export LC_ALL\n"
         "umask 022\n"
         "lease_pid=%d\n"
         "lease_identity=%@\n"
         "lease_is_live() {\n"
         "  current_identity=$(/bin/ps -ww -p \"$lease_pid\" -o pid= -o ppid= -o uid= -o lstart= -o command= 2>/dev/null) || return 1\n"
         "  [ \"$current_identity\" = \"$lease_identity\" ]\n"
         "}\n"
         "lease_is_live || exit 70\n"
         "status_dir=$(/usr/bin/mktemp -d /private/tmp/keepingyouawake-redbull.XXXXXXXX) || exit 71\n"
         "/bin/chmod 755 \"$status_dir\" || { /bin/rmdir \"$status_dir\"; exit 71; }\n"
         "lock_dir=/private/tmp/keepingyouawake-redbull.lock\n"
         "/bin/mkdir -m 755 \"$lock_dir\" 2>/dev/null || { /bin/rmdir \"$status_dir\"; exit 77; }\n"
         "setup_lock_owned=1\n"
         "setup_cleanup() {\n"
         "  if [ \"$setup_lock_owned\" = 1 ]; then /bin/rmdir \"$status_dir\" \"$lock_dir\" 2>/dev/null || :; fi\n"
         "}\n"
         "trap setup_cleanup 0\n"
         "watch_lease() {\n"
         "  owns_override=0\n"
         "  monitor_pid=\n"
         "  cleanup() {\n"
         "    trap - 0 1 2 15\n"
         "    restored=1\n"
         "    if [ \"$owns_override\" = 1 ]; then\n"
         "      restored=0\n"
         "      attempt=0\n"
         "      while [ \"$attempt\" -lt 5 ]; do\n"
         "        if /usr/bin/pmset -a disablesleep 0; then restored=1; break; fi\n"
         "        attempt=$((attempt + 1))\n"
         "        /bin/sleep 1\n"
         "      done\n"
         "    fi\n"
         "    if [ -n \"$monitor_pid\" ]; then\n"
         "      # A job reference cannot signal a recycled, unrelated PID.\n"
         "      kill %%1 2>/dev/null || :\n"
         "      wait \"$monitor_pid\" 2>/dev/null || :\n"
         "    fi\n"
         "    if [ \"$restored\" = 1 ]; then\n"
         "      /bin/rmdir \"$lock_dir\" 2>/dev/null || :\n"
         "      /bin/rm -rf -- \"$status_dir\"\n"
         "    else\n"
         "      /usr/bin/printf 'Normal sleep could not be restored.\\n' > \"$status_dir/cleanup-failed\"\n"
         "      /usr/bin/logger -t KeepingYouAwake 'Red Bull watchdog could not restore normal sleep.'\n"
         "    fi\n"
         "  }\n"
         "  trap cleanup 0\n"
         "  trap 'exit 74' 1 2 15\n"
         "  lease_is_live || exit 70\n"
         "  /usr/bin/caffeinate -i -w \"$lease_pid\" &\n"
         "  monitor_pid=$!\n"
         "  # caffeinate binds a kernel process-exit event to this lease.\n"
         "  # Recheck identity after starting it, before changing sleep policy.\n"
         "  lease_is_live || exit 70\n"
         "  /bin/kill -0 \"$monitor_pid\" 2>/dev/null || exit 72\n"
         "  owns_override=1\n"
         "  /usr/bin/pmset -a disablesleep 1 || exit 73\n"
         "  lease_is_live || exit 70\n"
         "  /bin/kill -0 \"$monitor_pid\" 2>/dev/null || exit 72\n"
         "  /usr/bin/printf 'ready\\n' > \"$status_dir/ready\" || exit 73\n"
         "  wait \"$monitor_pid\"\n"
         "  monitor_pid=\n"
         "  exit 0\n"
         "}\n"
         "watch_lease </dev/null >/dev/null 2>&1 &\n"
         "watchdog_pid=$!\n"
         "setup_lock_owned=0\n"
         "attempt=0\n"
         "while [ \"$attempt\" -lt 100 ]; do\n"
         "  if [ -f \"$status_dir/ready\" ] && /bin/kill -0 \"$watchdog_pid\" 2>/dev/null; then\n"
         "    /usr/bin/printf 'KYA_READY %%s %%s\\n' \"$watchdog_pid\" \"$status_dir\"\n"
         "    exit 0\n"
         "  fi\n"
         "  /bin/kill -0 \"$watchdog_pid\" 2>/dev/null || { wait \"$watchdog_pid\"; exit 75; }\n"
         "  attempt=$((attempt + 1))\n"
         "  /bin/sleep 0.1\n"
         "done\n"
         "kill %%1 2>/dev/null || :\n"
         "wait \"$watchdog_pid\" 2>/dev/null || :\n"
         "exit 76\n",
        leasePID, KYAShellQuotedString(leaseIdentity)];
}

@interface KYAClosedLidSession ()
@property (nonatomic, nullable) NSTask *lease;
@property (nonatomic, nullable) NSString *statusDirectory;
@property (nonatomic, readwrite, nullable) NSError *lastCleanupError;
@end

@implementation KYAClosedLidSession

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationWillTerminate:)
                                                   name:NSApplicationWillTerminateNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self endSession];
}

- (BOOL)active
{
    return self.lease.isRunning && self.statusDirectory != nil &&
        [NSFileManager.defaultManager fileExistsAtPath:[self.statusDirectory stringByAppendingPathComponent:@"ready"]] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[self.statusDirectory stringByAppendingPathComponent:@"cleanup-failed"]];
}

- (BOOL)beginSessionWithError:(NSError * _Nullable * _Nullable)error
{
    NSAssert(NSThread.isMainThread, @"Closed-lid sessions must be controlled on the main thread.");
    if(error != NULL) { *error = nil; }
    if(self.active) { return YES; }

    // A prior watchdog must finish its reset before a new one can take over;
    // otherwise late cleanup could disable a newly started session.
    [self endSession];
    if(self.statusDirectory != nil)
    {
        if(error != NULL)
        {
            *error = self.lastCleanupError ?: KYASessionError(KYAClosedLidSessionErrorCleanup, @"Normal sleep has not yet been restored from the previous Red Bull session. Try again in a moment.");
        }
        return NO;
    }

    pid_t appPID = getpid();
    if(appPID <= 0)
    {
        if(error != NULL) { *error = KYASessionError(KYAClosedLidSessionErrorLaunch, @"Could not identify this app's process."); }
        return NO;
    }

    NSTask *lease = [NSTask new];
    lease.executableURL = [NSURL fileURLWithPath:@"/usr/bin/caffeinate"];
    lease.arguments = @[@"-i", @"-w", [NSString stringWithFormat:@"%d", appPID]];
    lease.standardInput = NSFileHandle.fileHandleWithNullDevice;
    lease.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    lease.standardError = NSFileHandle.fileHandleWithNullDevice;

    NSError *launchError = nil;
    if(![lease launchAndReturnError:&launchError])
    {
        if(error != NULL) { *error = launchError ?: KYASessionError(KYAClosedLidSessionErrorLaunch, @"Could not start the Red Bull session lease."); }
        return NO;
    }
    self.lease = lease;

    NSString *identity = [self processIdentityForLease:lease error:&launchError];
    if(identity.length == 0 || !lease.isRunning)
    {
        [self endSession];
        if(error != NULL) { *error = launchError ?: KYASessionError(KYAClosedLidSessionErrorLaunch, @"The Red Bull session lease exited before it could be authenticated."); }
        return NO;
    }

    NSString *launcher = KYAPrivilegedLauncherScript(lease.processIdentifier, identity);
    NSString *command = [@"/usr/bin/env -i /bin/sh -c " stringByAppendingString:KYAShellQuotedString(launcher)];
    NSString *source = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", KYAAppleScriptQuotedString(command)];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *scriptError = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&scriptError];

    NSString *receipt = [result.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [receipt componentsSeparatedByString:@" "];
    BOOL receiptValid = (parts.count == 3 && [parts[0] isEqualToString:@"KYA_READY"]);
    if(receiptValid)
    {
        NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
        NSString *directory = parts[2];
        NSString *suffix = [directory stringByReplacingOccurrencesOfString:@"/private/tmp/keepingyouawake-redbull." withString:@""];
        NSCharacterSet *nonSuffixCharacters = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"].invertedSet;
        receiptValid = (parts[1].length > 0 && [parts[1] rangeOfCharacterFromSet:nonDigits].location == NSNotFound &&
                        parts[1].longLongValue > 0 && [directory hasPrefix:@"/private/tmp/keepingyouawake-redbull."] &&
                        suffix.length == 8 && [suffix rangeOfCharacterFromSet:nonSuffixCharacters].location == NSNotFound);
        if(receiptValid) { self.statusDirectory = directory; }
    }

    if(result == nil || !receiptValid || !self.active)
    {
        [self endSession];
        if(error != NULL)
        {
            NSInteger scriptCode = [scriptError[NSAppleScriptErrorNumber] integerValue];
            if(scriptCode == -128)
            {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
            }
            else
            {
                NSString *description = scriptCode == 77 ? @"Another Red Bull session is active, or a previous session has not finished restoring normal sleep." : scriptError[NSAppleScriptErrorMessage];
                if(description.length == 0) { description = @"The privileged watchdog could not confirm that Red Bull mode was activated."; }
                *error = KYASessionError(result == nil ? KYAClosedLidSessionErrorAuthentication : KYAClosedLidSessionErrorWatchdog, description);
            }
        }
        return NO;
    }

    return YES;
}

- (nullable NSString *)processIdentityForLease:(NSTask *)lease error:(NSError * _Nullable * _Nullable)error
{
    if(lease.processIdentifier <= 0) { return nil; }

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/ps"];
    task.arguments = @[@"-ww", @"-p", [NSString stringWithFormat:@"%d", lease.processIdentifier],
                       @"-o", @"pid=", @"-o", @"ppid=", @"-o", @"uid=", @"-o", @"lstart=", @"-o", @"command="];
    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"LC_ALL"] = @"C";
    task.environment = environment;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if(![task launchAndReturnError:error]) { return nil; }

    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if(task.terminationStatus != 0) { return nil; }
    NSString *identity = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // Shell command substitution strips trailing newlines, but not leading
    // whitespace. Match that behavior precisely for the watchdog comparison.
    return [identity stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
}

- (void)endSession
{
    self.lastCleanupError = nil;
    NSTask *lease = self.lease;
    self.lease = nil;
    if(lease.isRunning)
    {
        [lease terminate];
        [lease waitUntilExit];
    }

    if(self.statusDirectory == nil) { return; }

    // Do not reauthenticate for cleanup. The already-authorized root watchdog
    // owns the reset. Retain an unacknowledged directory to prevent overlapping
    // sessions, and allow the next begin/end call to check it again.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6];
    while([NSFileManager.defaultManager fileExistsAtPath:self.statusDirectory] && deadline.timeIntervalSinceNow > 0)
    {
        if([NSFileManager.defaultManager fileExistsAtPath:[self.statusDirectory stringByAppendingPathComponent:@"cleanup-failed"]])
        {
            self.lastCleanupError = KYASessionError(KYAClosedLidSessionErrorCleanup, @"Red Bull mode could not restore normal sleep. Run sudo pmset -a disablesleep 0 in Terminal to restore it.");
            NSLog(@"%@", self.lastCleanupError.localizedDescription);
            return;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    if(![NSFileManager.defaultManager fileExistsAtPath:self.statusDirectory]) { self.statusDirectory = nil; }
    else
    {
        self.lastCleanupError = KYASessionError(KYAClosedLidSessionErrorCleanup, @"Red Bull mode is still waiting for its privileged watchdog to restore normal sleep. Try again in a moment.");
        NSLog(@"%@", self.lastCleanupError.localizedDescription);
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self endSession];
}

@end

NS_ASSUME_NONNULL_END
