#import "KYAClosedLidSession.h"
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <poll.h>
#import <math.h>
#import <string.h>

#if __has_include("KYAHelperBuildIdentity.h")
#import "KYAHelperBuildIdentity.h"
#else
#define COFFEEBULL_HELPER_SHA256 @""
#endif

NSErrorDomain const KYAClosedLidSessionErrorDomain = @"KYAClosedLidSessionErrorDomain";
static NSString * const KYAHelperLabel = @"app.byrvr.CoffeeBull.Helper";
static NSString * const KYAHelperSocket = @"/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.sock";

typedef NS_ENUM(NSInteger, KYAHelperError) {
    KYAHelperUnavailable = 1,
    KYAHelperUnauthorized,
    KYAHelperOperationFailed,
    KYAHelperSetupFailed
};

static NSError *KYAHelperMakeError(KYAHelperError code, NSString *message)
{
    return [NSError errorWithDomain:KYAClosedLidSessionErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *KYAShellQuote(NSString *value)
{
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *KYAAppleScriptQuote(NSString *value)
{
    value = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    value = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    value = [value stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", value];
}

static NSString *KYACurrentCodeHash(void)
{
    SecCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    if(SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) { return nil; }
    OSStatus result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    CFRelease(code);
    if(result != errSecSuccess) { return nil; }
    NSDictionary *details = CFBridgingRelease(information);
    NSData *hash = details[(__bridge NSString *)kSecCodeInfoUnique];
    if(![hash isKindOfClass:NSData.class] || hash.length != 20) { return nil; }
    const unsigned char *bytes = hash.bytes;
    NSMutableString *hex = [NSMutableString new];
    for(NSUInteger i = 0; i < hash.length; i++) { [hex appendFormat:@"%02x", bytes[i]]; }
    return hex;
}

@interface KYAClosedLidSession ()
@property (nonatomic, readwrite, nullable) NSError *lastCleanupError;
@property (nonatomic) BOOL ownsSession;
@end

@implementation KYAClosedLidSession

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillTerminate:)
                                                   name:NSApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self endSession];
}

- (NSDictionary *)request:(NSString *)command error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    return [self request:command timeout:8 error:error];
}

- (NSDictionary *)request:(NSString *)command timeout:(NSTimeInterval)seconds error:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    BOOL previouslyOwned = self.ownsSession;
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if(descriptor < 0)
    {
        if(error) { *error = KYAHelperMakeError(KYAHelperUnavailable, @"CoffeeBull's sleep helper is not available."); }
        return nil;
    }
    struct timeval timeout = {(time_t)seconds, (suseconds_t)((seconds - floor(seconds)) * 1000000)};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int noSignal = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, KYAHelperSocket.fileSystemRepresentation, sizeof(address.sun_path));
    int flags = fcntl(descriptor, F_GETFL, 0);
    fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
    int connected = connect(descriptor, (struct sockaddr *)&address, sizeof(address));
    int connectionError = connected == 0 ? 0 : errno;
    if(connectionError == EINPROGRESS || connectionError == EAGAIN)
    {
        struct pollfd waiter = {descriptor, POLLOUT, 0};
        int ready = poll(&waiter, 1, (int)ceil(seconds * 1000));
        socklen_t length = sizeof(connectionError);
        if(ready <= 0 || getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &length) != 0) { connectionError = ETIMEDOUT; }
    }
    fcntl(descriptor, F_SETFL, flags);
    if(connectionError != 0)
    {
        close(descriptor);
        KYAHelperError code = (connectionError == ENOENT || connectionError == ECONNREFUSED) ? KYAHelperUnavailable : KYAHelperOperationFailed;
        if(error) { *error = KYAHelperMakeError(code, code == KYAHelperUnavailable ? @"CoffeeBull needs its one-time sleep helper setup." : @"The sleep helper connection timed out. Try again."); }
        return nil;
    }
    uid_t peerUID;
    gid_t peerGID;
    if(getpeereid(descriptor, &peerUID, &peerGID) != 0 || peerUID != 0)
    {
        close(descriptor);
        if(error) { *error = KYAHelperMakeError(KYAHelperOperationFailed, @"The sleep helper's identity could not be verified."); }
        return nil;
    }
    NSData *request = [[command stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *requestBytes = request.bytes;
    NSUInteger sent = 0;
    while(sent < request.length && NSProcessInfo.processInfo.systemUptime < deadline)
    {
        ssize_t count = write(descriptor, requestBytes + sent, request.length - sent);
        if(count < 0 && errno == EINTR) { continue; }
        if(count <= 0) { break; }
        sent += (NSUInteger)count;
    }
    if(sent == request.length && [command isEqual:@"ON"]) { self.ownsSession = YES; }
    NSMutableData *response = [NSMutableData new];
    unsigned char buffer[512];
    // A helper pinned to an older build may reject and close before our write.
    // Read its response even after EPIPE so renewal can recognize that rejection.
    while(response.length < 8192)
    {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if(remaining <= 0) { break; }
        timeout.tv_sec = (time_t)remaining;
        timeout.tv_usec = (suseconds_t)((remaining - floor(remaining)) * 1000000);
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        ssize_t count = read(descriptor, buffer, sizeof(buffer));
        if(count < 0 && errno == EINTR) { continue; }
        if(count <= 0) { break; }
        [response appendBytes:buffer length:(NSUInteger)count];
        if(memchr(buffer, '\n', (size_t)count)) { break; }
    }
    close(descriptor);
    id payload = response.length ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
    if(![payload isKindOfClass:NSDictionary.class] ||
       ![payload[@"protocol"] isKindOfClass:NSNumber.class] || [payload[@"protocol"] integerValue] != 2 ||
       ![payload[@"ok"] isKindOfClass:NSNumber.class] ||
       ![payload[@"active"] isKindOfClass:NSNumber.class] ||
       ![payload[@"owner_pid"] isKindOfClass:NSNumber.class])
    {
        if(error) { *error = KYAHelperMakeError(KYAHelperOperationFailed, @"The sleep helper did not return a valid response."); }
        return nil;
    }
    if(![payload[@"ok"] boolValue])
    {
        NSString *reason = [payload[@"error"] isKindOfClass:NSString.class] ? payload[@"error"] : @"The sleep helper could not complete this request.";
        NSString *kind = payload[@"error_code"];
        if(!previouslyOwned && ([kind isEqual:@"unauthorized"] || [kind isEqual:@"ownership"] || [kind isEqual:@"protocol"])) { self.ownsSession = NO; }
        KYAHelperError code = [kind isEqual:@"unauthorized"] ? KYAHelperUnauthorized : KYAHelperOperationFailed;
        if(error) { *error = KYAHelperMakeError(code, reason); }
        return nil;
    }
    return payload;
}

- (BOOL)active
{
    if(!self.ownsSession) { return NO; }
    NSDictionary *response = [self request:@"STATUS" error:nil];
    return [response[@"active"] boolValue] && [response[@"owner_pid"] intValue] == getpid();
}

- (BOOL)setupHelperWithError:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    NSString *codeHash = KYACurrentCodeHash();
    NSString *helper = [NSBundle.mainBundle pathForResource:@"CoffeeBullHelper" ofType:nil];
    if(codeHash.length != 40 || COFFEEBULL_HELPER_SHA256.length != 64 || helper == nil)
    {
        if(error) { *error = KYAHelperMakeError(KYAHelperSetupFailed, @"This build is missing its signed sleep helper. Build CoffeeBull with scripts/build-local.sh."); }
        return NO;
    }
    if(![NSBundle.mainBundle.bundlePath isEqual:@"/Applications/CoffeeBull.app"])
    {
        if(error) { *error = KYAHelperMakeError(KYAHelperSetupFailed, @"Install CoffeeBull in Applications before setting up Red Bull."); }
        return NO;
    }
    NSDictionary *definition = @{
        @"Label": KYAHelperLabel,
        @"ProgramArguments": @[@"/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.Helper", @"--uid", [NSString stringWithFormat:@"%u", getuid()], @"--cdhash", codeHash],
        @"RunAtLoad": @YES, @"KeepAlive": @YES, @"ThrottleInterval": @5,
        @"ProcessType": @"Background", @"ExitTimeOut": @15
    };
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:definition format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if(plistData == nil) { return NO; }
    NSString *plist = [[NSString alloc] initWithData:plistData encoding:NSUTF8StringEncoding];
    NSString *launcher = [NSString stringWithFormat:
        @"set -eu\n"
         "PATH=/usr/bin:/bin:/usr/sbin:/sbin\nexport PATH\numask 022\n"
         "tools=/Library/PrivilegedHelperTools\n"
         "daemons=/Library/LaunchDaemons\n"
         "target=$tools/app.byrvr.CoffeeBull.Helper\n"
         "plist=$daemons/app.byrvr.CoffeeBull.Helper.plist\n"
         "for directory in \"$tools\" \"$daemons\"; do\n"
         "  [ ! -L \"$directory\" ] || exit 80\n"
         "  /bin/mkdir -p \"$directory\"\n"
         "  [ \"$(/usr/bin/stat -f %%u \"$directory\")\" = 0 ] || exit 80\n"
         "  permissions=$(/usr/bin/stat -f %%Lp \"$directory\")\n"
         "  [ $((0$permissions & 0022)) -eq 0 ] || exit 80\n"
         "done\n"
         "[ ! -L \"$target\" ] && [ ! -L \"$plist\" ] || exit 80\n"
         "stage=$(/usr/bin/mktemp -d \"$tools/.coffeebull-install.XXXXXXXX\")\n"
         "trap '/bin/rm -rf -- \"$stage\"' EXIT\n"
         "/usr/bin/install -o root -g wheel -m 755 %@ \"$stage/helper\"\n"
         "digest=$(/usr/bin/shasum -a 256 \"$stage/helper\" | /usr/bin/awk '{print $1}')\n"
         "[ \"$digest\" = %@ ] || exit 81\n"
         "/usr/bin/printf %%s %@ > \"$stage/daemon.plist\"\n"
         "/usr/bin/plutil -lint \"$stage/daemon.plist\" >/dev/null\n"
         "/usr/sbin/chown root:wheel \"$stage/daemon.plist\"\n"
         "/bin/chmod 644 \"$stage/daemon.plist\"\n"
         "/bin/launchctl bootout system/app.byrvr.CoffeeBull.Helper >/dev/null 2>&1 || :\n"
         "/bin/mv -f \"$stage/helper\" \"$target\"\n"
         "/bin/mv -f \"$stage/daemon.plist\" \"$plist\"\n"
         "/bin/launchctl bootstrap system \"$plist\"\n",
        KYAShellQuote(helper), KYAShellQuote(COFFEEBULL_HELPER_SHA256), KYAShellQuote(plist)];
    NSString *command = [@"/usr/bin/env -i /bin/sh -c " stringByAppendingString:KYAShellQuote(launcher)];
    NSString *source = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", KYAAppleScriptQuote(command)];
    NSDictionary *scriptError = nil;
    NSAppleEventDescriptor *result = [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&scriptError];
    if(result == nil)
    {
        if(error)
        {
            if([scriptError[NSAppleScriptErrorNumber] integerValue] == -128)
            {
                *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
            }
            else
            {
                *error = KYAHelperMakeError(KYAHelperSetupFailed, scriptError[NSAppleScriptErrorMessage] ?: @"The one-time sleep helper setup failed.");
            }
        }
        return NO;
    }
    NSTimeInterval setupDeadline = NSProcessInfo.processInfo.systemUptime + 8;
    while(NSProcessInfo.processInfo.systemUptime < setupDeadline)
    {
        NSTimeInterval remaining = setupDeadline - NSProcessInfo.processInfo.systemUptime;
        if([self request:@"STATUS" timeout:MIN(0.2, remaining) error:nil] != nil) { return YES; }
        [NSThread sleepForTimeInterval:0.1];
    }
    if(error) { *error = KYAHelperMakeError(KYAHelperSetupFailed, @"The sleep helper was installed but has not started. Try Red Bull again."); }
    return NO;
}

- (BOOL)beginSessionWithError:(NSError * _Nullable __autoreleasing * _Nullable)error
{
    NSAssert(NSThread.isMainThread, @"Control Red Bull on the main thread.");
    if(error) { *error = nil; }
    if(self.ownsSession && self.lastCleanupError != nil)
    {
        [self endSession];
        if(self.ownsSession)
        {
            if(error) { *error = self.lastCleanupError; }
            return NO;
        }
    }
    self.lastCleanupError = nil;
    NSError *requestError = nil;
    NSDictionary *response = [self request:@"ON" error:&requestError];
    if(response == nil && (requestError.code == KYAHelperUnavailable || requestError.code == KYAHelperUnauthorized))
    {
        if(![self setupHelperWithError:error]) { [self endSession]; return NO; }
        response = [self request:@"ON" error:&requestError];
    }
    if(![response[@"active"] boolValue] || [response[@"owner_pid"] intValue] != getpid())
    {
        [self endSession];
        if(error) { *error = self.lastCleanupError ?: requestError ?: KYAHelperMakeError(KYAHelperOperationFailed, @"Red Bull could not confirm its sleep override."); }
        return NO;
    }
    self.ownsSession = YES;
    return YES;
}

- (void)endSession
{
    if(!self.ownsSession) { return; }
    NSError *error = nil;
    NSDictionary *response = [self request:@"OFF" error:&error];
    if(response == nil || [response[@"active"] boolValue])
    {
        self.lastCleanupError = error ?: KYAHelperMakeError(KYAHelperOperationFailed, @"Normal sleep could not be restored. Quit CoffeeBull to release its helper lease, or run sudo pmset -a disablesleep 0 in Terminal.");
        return;
    }
    self.ownsSession = NO;
    self.lastCleanupError = nil;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self endSession];
}

@end
