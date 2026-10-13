// CoffeeBull's deliberately small privileged service. It accepts three fixed
// operations from the exact app code approved at installation, and nothing else.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <bsm/libbsm.h>
#import <libproc.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/select.h>
#import <sys/time.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <time.h>

static const char *CBSocketPath = "/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.sock";
static const char *CBMarkerPath = "/Library/PrivilegedHelperTools/app.byrvr.CoffeeBull.active";
static const char *CBMarkerMagic = "COFFEEBULL_OWNED_V2\n";
static NSString * const CBApprovedIdentifier = @"app.byrvr.CoffeeBull";
static volatile sig_atomic_t CBShouldStop = 0;

static double CBMonotonicTime(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static void CBSignalHandler(int signalNumber)
{
    (void)signalNumber;
    CBShouldStop = 1;
}

static BOOL CBPeerMatchesPolicy(uid_t actualUID, uid_t approvedUID, BOOL validCode,
                               NSString *identifier, NSData *hash, NSData *approvedHash)
{
    return actualUID == approvedUID && validCode &&
        [identifier isEqualToString:CBApprovedIdentifier] &&
        hash.length == 20 && approvedHash.length == 20 && [hash isEqualToData:approvedHash];
}

// The audit token comes from the kernel socket peer, never from the request.
// Security uses its PID version as well as its PID, preventing PID reuse races.
static BOOL CBValidateAuditToken(audit_token_t token, uid_t approvedUID, NSData *approvedHash)
{
    if(audit_token_to_euid(token) != approvedUID || audit_token_to_pid(token) <= 0) { return NO; }
    NSData *auditData = [NSData dataWithBytes:&token length:sizeof(token)];
    NSDictionary *attributes = @{ (__bridge NSString *)kSecGuestAttributeAudit: auditData };
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes,
                                                    kSecCSDefaultFlags, &code);
    if(status != errSecSuccess || code == NULL) { return NO; }
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
    CFDictionaryRef information = NULL;
    if(status == errSecSuccess)
    {
        status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    }
    CFRelease(code);
    if(status != errSecSuccess || information == NULL) { return NO; }
    NSDictionary *details = CFBridgingRelease(information);
    return CBPeerMatchesPolicy(audit_token_to_euid(token), approvedUID, YES,
                              details[(__bridge NSString *)kSecCodeInfoIdentifier],
                              details[(__bridge NSString *)kSecCodeInfoUnique], approvedHash);
}

static BOOL CBAuthenticateSocket(int socketFD, uid_t approvedUID, NSData *approvedHash,
                                audit_token_t *token)
{
    uid_t peerUID = (uid_t)-1;
    gid_t peerGID = (gid_t)-1;
    if(getpeereid(socketFD, &peerUID, &peerGID) != 0 || peerUID != approvedUID) { return NO; }
    socklen_t tokenLength = sizeof(*token);
    memset(token, 0, sizeof(*token));
    if(getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERTOKEN, token, &tokenLength) != 0 ||
       tokenLength != sizeof(*token)) { return NO; }
    return CBValidateAuditToken(*token, approvedUID, approvedHash);
}

static NSString *CBVerbForData(NSData *data)
{
    if([data isEqualToData:[@"ON\n" dataUsingEncoding:NSUTF8StringEncoding]]) { return @"ON"; }
    if([data isEqualToData:[@"OFF\n" dataUsingEncoding:NSUTF8StringEncoding]]) { return @"OFF"; }
    if([data isEqualToData:[@"STATUS\n" dataUsingEncoding:NSUTF8StringEncoding]]) { return @"STATUS"; }
    return nil;
}

static BOOL CBRunPMSet(NSArray<NSString *> *arguments, NSString **output, NSString **error)
{
    // All callers pass one of three literal arrays. No shell, caller-provided
    // arguments, executable paths, environment, or working directory is used.
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
    task.arguments = arguments;
    task.environment = @{ @"PATH": @"/usr/bin:/bin:/usr/sbin:/sbin", @"LC_ALL": @"C" };
    task.currentDirectoryURL = [NSURL fileURLWithPath:@"/"];
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = output != NULL ? [NSPipe pipe] : nil;
    task.standardOutput = pipe ?: NSFileHandle.fileHandleWithNullDevice;
    NSError *launchError = nil;
    if(![task launchAndReturnError:&launchError])
    {
        if(error != NULL) { *error = @"The system power command could not be started."; }
        return NO;
    }
    double deadline = CBMonotonicTime() + 5.0;
    while(task.isRunning && CBMonotonicTime() < deadline) { usleep(20000); }
    if(task.isRunning)
    {
        [task terminate];
        double terminationDeadline = CBMonotonicTime() + 0.25;
        while(task.isRunning && CBMonotonicTime() < terminationDeadline) { usleep(10000); }
        if(task.isRunning) { kill(task.processIdentifier, SIGKILL); }
        [task waitUntilExit];
        if(error != NULL) { *error = @"The system power command timed out."; }
        return NO;
    }
    if(output != NULL)
    {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    if(task.terminationReason != NSTaskTerminationReasonExit || task.terminationStatus != 0)
    {
        if(error != NULL) { *error = @"The system power command failed."; }
        return NO;
    }
    return YES;
}

static BOOL CBWriteSleepFlag(BOOL disabled, NSString **error)
{
    return CBRunPMSet(disabled ? @[@"-a", @"disablesleep", @"1"] : @[@"-a", @"disablesleep", @"0"], NULL, error);
}

static NSNumber *CBReadSleepFlag(NSString **error)
{
    NSString *output = nil;
    if(!CBRunPMSet(@[@"-g"], &output, error)) { return nil; }
    for(NSString *line in [output componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
    {
        NSArray<NSString *> *parts = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if(parts.count == 2 && [parts[0] isEqualToString:@"SleepDisabled"] &&
           ([parts[1] isEqualToString:@"0"] || [parts[1] isEqualToString:@"1"]))
        {
            return @([parts[1] isEqualToString:@"1"]);
        }
    }
    if(error != NULL) { *error = @"The system sleep setting could not be read back."; }
    return nil;
}

static BOOL CBProtectedDirectory(const char *path)
{
    struct stat information;
    return lstat(path, &information) == 0 && S_ISDIR(information.st_mode) &&
        information.st_uid == 0 && (information.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static BOOL CBMarkerIsValid(int descriptor)
{
    struct stat information;
    char contents[64] = {0};
    size_t expectedLength = strlen(CBMarkerMagic);
    if(fstat(descriptor, &information) != 0 || !S_ISREG(information.st_mode) ||
       information.st_uid != 0 || (information.st_mode & 07777) != 0600 ||
       information.st_nlink != 1 || information.st_size != (off_t)expectedLength) { return NO; }
    ssize_t length = pread(descriptor, contents, sizeof(contents), 0);
    return length == (ssize_t)expectedLength && memcmp(contents, CBMarkerMagic, expectedLength) == 0;
}

static BOOL CBMarkerPresent(BOOL *present, NSString **error)
{
    *present = NO;
    if(!CBProtectedDirectory("/Library") || !CBProtectedDirectory("/Library/PrivilegedHelperTools"))
    {
        if(error != NULL) { *error = @"The privileged helper directory is not protected."; }
        return NO;
    }
    int descriptor = open(CBMarkerPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if(descriptor < 0)
    {
        if(errno == ENOENT) { return YES; }
        if(error != NULL) { *error = @"The Red Bull recovery marker could not be opened."; }
        return NO;
    }
    BOOL valid = CBMarkerIsValid(descriptor);
    close(descriptor);
    if(!valid)
    {
        if(error != NULL) { *error = @"The Red Bull recovery marker is invalid."; }
        return NO;
    }
    *present = YES;
    return YES;
}

static BOOL CBCreateMarker(NSString **error)
{
    if(!CBProtectedDirectory("/Library") || !CBProtectedDirectory("/Library/PrivilegedHelperTools"))
    {
        if(error != NULL) { *error = @"The privileged helper directory is not protected."; }
        return NO;
    }
    int descriptor = open(CBMarkerPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if(descriptor < 0)
    {
        if(error != NULL) { *error = @"The Red Bull recovery marker could not be created."; }
        return NO;
    }
    size_t length = strlen(CBMarkerMagic);
    BOOL complete = write(descriptor, CBMarkerMagic, length) == (ssize_t)length && fsync(descriptor) == 0;
    close(descriptor);
    if(!complete)
    {
        unlink(CBMarkerPath);
        if(error != NULL) { *error = @"The Red Bull recovery marker could not be saved."; }
        return NO;
    }
    // The marker must be durable before the global setting can be changed.
    int directory = open("/Library/PrivilegedHelperTools", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    BOOL durable = directory >= 0 && fsync(directory) == 0;
    if(directory >= 0) { close(directory); }
    if(!durable)
    {
        unlink(CBMarkerPath);
        if(error != NULL) { *error = @"The Red Bull recovery marker could not be made durable."; }
        return NO;
    }
    return YES;
}

static BOOL CBRemoveMarker(NSString **error)
{
    BOOL present = NO;
    if(!CBMarkerPresent(&present, error)) { return NO; }
    if(!present) { return YES; }
    if(unlink(CBMarkerPath) != 0)
    {
        if(error != NULL) { *error = @"Normal sleep was restored, but the recovery marker could not be removed."; }
        return NO;
    }
    int directory = open("/Library/PrivilegedHelperTools", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    BOOL durable = directory >= 0 && fsync(directory) == 0;
    if(directory >= 0) { close(directory); }
    if(!durable)
    {
        if(error != NULL) { *error = @"The recovery marker removal could not be made durable."; }
        return NO;
    }
    return YES;
}

typedef BOOL (^CBFlagWriter)(BOOL disabled, NSString **error);
typedef NSNumber *(^CBFlagReader)(NSString **error);
typedef BOOL (^CBMarkerOperation)(NSString **error);
typedef BOOL (^CBOwnerValidator)(audit_token_t token);

@interface CBSleepLease : NSObject
@property (nonatomic) BOOL active;
@property (nonatomic) audit_token_t owner;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) CBFlagWriter writeFlag;
@property (nonatomic, copy) CBFlagReader readFlag;
@property (nonatomic, copy) CBMarkerOperation createMarker;
@property (nonatomic, copy) CBMarkerOperation removeMarker;
@property (nonatomic, copy) CBOwnerValidator ownerIsLive;
- (NSDictionary *)perform:(NSString *)verb peer:(audit_token_t)peer;
- (BOOL)restore;
- (void)pollOwner;
@end

@implementation CBSleepLease

- (BOOL)sameOwner:(audit_token_t)peer
{
    return audit_token_to_pid(self.owner) > 0 &&
        audit_token_to_pid(self.owner) == audit_token_to_pid(peer) &&
        audit_token_to_pidversion(self.owner) == audit_token_to_pidversion(peer);
}

- (NSDictionary *)reply:(BOOL)ok error:(NSString *)error code:(NSString *)code
{
    return @{ @"ok": @(ok), @"active": @(self.active), @"error": error ?: NSNull.null,
              @"error_code": code ?: NSNull.null, @"protocol": @2,
              @"owner_pid": @(self.active ? audit_token_to_pid(self.owner) : 0) };
}

- (BOOL)restore
{
    if(!self.active) { return YES; }
    NSString *error = nil;
    if(!self.writeFlag(NO, &error))
    {
        self.lastError = error ?: @"Normal sleep could not be restored.";
        return NO;
    }
    NSNumber *disabled = self.readFlag(&error);
    if(disabled == nil || disabled.boolValue)
    {
        self.lastError = error ?: @"Normal sleep could not be confirmed.";
        return NO;
    }
    if(!self.removeMarker(&error))
    {
        self.lastError = error ?: @"The Red Bull recovery marker could not be removed.";
        return NO;
    }
    self.active = NO;
    self.owner = (audit_token_t){0};
    self.lastError = nil;
    return YES;
}

- (void)pollOwner
{
    if(self.active && (self.lastError != nil || audit_token_to_pid(self.owner) <= 0 || !self.ownerIsLive(self.owner)))
    {
        if(![self restore]) { NSLog(@"CoffeeBull: %@", self.lastError); }
    }
}

- (NSDictionary *)perform:(NSString *)verb peer:(audit_token_t)peer
{
    [self pollOwner];
    if(![@[@"ON", @"OFF", @"STATUS"] containsObject:verb ?: @""])
    {
        return [self reply:NO error:@"Only ON, OFF, or STATUS is accepted." code:@"protocol"];
    }
    if([verb isEqualToString:@"STATUS"])
    {
        if(self.active)
        {
            NSString *error = nil;
            NSNumber *disabled = self.readFlag(&error);
            if(self.lastError != nil || disabled == nil || !disabled.boolValue)
            {
                return [self reply:NO error:self.lastError ?: error ?: @"Red Bull's sleep setting was changed outside CoffeeBull." code:@"power"];
            }
        }
        return [self reply:YES error:nil code:nil];
    }
    if(self.active && ![self sameOwner:peer])
    {
        return [self reply:NO error:self.lastError ?: @"Another CoffeeBull instance owns Red Bull mode." code:self.lastError ? @"power" : @"ownership"];
    }
    if([verb isEqualToString:@"OFF"])
    {
        BOOL restored = [self restore];
        return [self reply:restored error:restored ? nil : self.lastError code:restored ? nil : @"power"];
    }
    if(self.active)
    {
        return [self reply:self.lastError == nil error:self.lastError code:self.lastError ? @"power" : nil];
    }
    if(!self.ownerIsLive(peer))
    {
        return [self reply:NO error:@"The approved app exited before activation." code:@"unauthorized"];
    }
    NSString *error = nil;
    if(!self.createMarker(&error))
    {
        return [self reply:NO error:error ?: @"The Red Bull recovery marker could not be saved." code:@"power"];
    }
    // Ownership precedes the write, so even a partial or timed-out command is
    // followed by a reset. A failed reset keeps the marker and is retried.
    self.active = YES;
    self.owner = peer;
    BOOL enabled = self.writeFlag(YES, &error);
    NSNumber *disabled = enabled ? self.readFlag(&error) : nil;
    if(!enabled || disabled == nil || !disabled.boolValue || !self.ownerIsLive(peer))
    {
        NSString *activationError = error ?: @"Red Bull mode could not be confirmed.";
        BOOL restored = [self restore];
        return [self reply:NO error:restored ? activationError : self.lastError code:@"power"];
    }
    return [self reply:YES error:nil code:nil];
}
@end

static BOOL CBWaitForSocket(int descriptor, BOOL writing, double deadline)
{
    double remaining = deadline - CBMonotonicTime();
    if(remaining <= 0 || CBShouldStop) { return NO; }
    struct timeval timeout = { .tv_sec = (time_t)remaining,
                               .tv_usec = (suseconds_t)((remaining - floor(remaining)) * 1e6) };
    fd_set descriptors;
    FD_ZERO(&descriptors);
    FD_SET(descriptor, &descriptors);
    int ready = select(descriptor + 1, writing ? NULL : &descriptors,
                       writing ? &descriptors : NULL, NULL, &timeout);
    return ready > 0;
}

static NSData *CBReadRequest(int descriptor)
{
    uint8_t bytes[128];
    size_t count = 0;
    double deadline = CBMonotonicTime() + 0.5;
    while(count < sizeof(bytes) && CBWaitForSocket(descriptor, NO, deadline))
    {
        ssize_t length = recv(descriptor, bytes + count, sizeof(bytes) - count, 0);
        if(length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) { continue; }
        if(length <= 0) { break; }
        count += (size_t)length;
        if(memchr(bytes, '\n', count) != NULL) { return [NSData dataWithBytes:bytes length:count]; }
    }
    return nil;
}

static void CBWriteReply(int descriptor, NSDictionary *reply)
{
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL] mutableCopy];
    [data appendBytes:"\n" length:1];
    const uint8_t *bytes = data.bytes;
    size_t count = 0;
    double deadline = CBMonotonicTime() + 0.5;
    while(count < data.length && CBWaitForSocket(descriptor, YES, deadline))
    {
        ssize_t length = send(descriptor, bytes + count, data.length - count, 0);
        if(length < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) { continue; }
        if(length <= 0) { break; }
        count += (size_t)length;
    }
}

static int CBCreateListener(uid_t approvedUID, struct stat *createdSocket, NSString **error)
{
    // The containing root-owned directory is already needed for the helper
    // executable and recovery marker. The app cannot replace socket entries.
    if(!CBProtectedDirectory("/Library") || !CBProtectedDirectory("/Library/PrivilegedHelperTools"))
    {
        *error = @"The local socket directory is not protected.";
        return -1;
    }
    struct stat existing;
    if(lstat(CBSocketPath, &existing) == 0)
    {
        if(!S_ISSOCK(existing.st_mode) || existing.st_uid != approvedUID ||
           (existing.st_mode & 07777) != 0600)
        {
            *error = @"A conflicting local socket exists.";
            return -1;
        }
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        if(probe < 0) { *error = @"The existing local socket could not be checked."; return -1; }
        fcntl(probe, F_SETFD, FD_CLOEXEC);
        fcntl(probe, F_SETFL, O_NONBLOCK);
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        strlcpy(address.sun_path, CBSocketPath, sizeof(address.sun_path));
        int result = connect(probe, (struct sockaddr *)&address, sizeof(address));
        int connectionError = result == 0 ? 0 : errno;
        close(probe);
        if(connectionError != ECONNREFUSED && connectionError != ENOENT)
        {
            *error = @"Another CoffeeBull helper is already listening.";
            return -1;
        }
        struct stat checked;
        if(lstat(CBSocketPath, &checked) != 0 || checked.st_dev != existing.st_dev ||
           checked.st_ino != existing.st_ino || unlink(CBSocketPath) != 0)
        {
            *error = @"The stale local socket could not be removed safely.";
            return -1;
        }
    }
    else if(errno != ENOENT) { *error = @"The local socket could not be inspected."; return -1; }
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if(descriptor < 0) { *error = @"The local socket could not be created."; return -1; }
    fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    fcntl(descriptor, F_SETFL, O_NONBLOCK);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, CBSocketPath, sizeof(address.sun_path));
    BOOL bound = bind(descriptor, (struct sockaddr *)&address, sizeof(address)) == 0;
    if(!bound || chmod(CBSocketPath, 0600) != 0 || chown(CBSocketPath, approvedUID, 0) != 0 ||
       lstat(CBSocketPath, createdSocket) != 0 || listen(descriptor, 8) != 0)
    {
        close(descriptor);
        if(bound) { unlink(CBSocketPath); }
        *error = @"The local socket could not be protected or started.";
        return -1;
    }
    return descriptor;
}

static NSData *CBHashFromString(NSString *string)
{
    if(string.length != 40) { return nil; }
    NSMutableData *data = [NSMutableData dataWithCapacity:20];
    for(NSUInteger index = 0; index < string.length; index += 2)
    {
        NSString *pair = [string substringWithRange:NSMakeRange(index, 2)];
        if([pair rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet].location != NSNotFound) { return nil; }
        unsigned int value = 0;
        if(![[NSScanner scannerWithString:pair] scanHexInt:&value]) { return nil; }
        uint8_t byte = (uint8_t)value;
        [data appendBytes:&byte length:1];
    }
    return data;
}

// Safe deterministic tests: all power commands, persistent files, and process
// lifetimes below are simulated. --self-test requires no admin rights.
static int CBSelfTest(void)
{
    __block NSUInteger failures = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *description) {
        if(!passed) { fprintf(stderr, "FAIL: %s\n", description.UTF8String); failures++; }
    };
    NSData *hash = CBHashFromString(@"00112233445566778899aabbccddeeff00112233");
    check(CBPeerMatchesPolicy(501, 501, YES, CBApprovedIdentifier, hash, hash), @"approved identity");
    check(!CBPeerMatchesPolicy(502, 501, YES, CBApprovedIdentifier, hash, hash), @"wrong user rejected");
    check(!CBPeerMatchesPolicy(501, 501, NO, CBApprovedIdentifier, hash, hash), @"invalid code rejected");
    check(!CBPeerMatchesPolicy(501, 501, YES, @"other", hash, hash), @"spoofed identifier rejected");
    check(!CBPeerMatchesPolicy(501, 501, YES, CBApprovedIdentifier, hash, [NSData data]), @"unpinned code rejected");
    for(NSString *verb in @[@"ON", @"OFF", @"STATUS"])
    {
        NSData *data = [[verb stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        check([CBVerbForData(data) isEqualToString:verb], [@"valid verb " stringByAppendingString:verb]);
    }
    for(NSString *invalid in @[@"ON", @"ON\nOFF\n", @"ON /bin/sh\n", @"STATUS \n", @"on\n", @"\n"])
    {
        check(CBVerbForData([invalid dataUsingEncoding:NSUTF8StringEncoding]) == nil, @"invalid request rejected");
    }
    const uint8_t nulRequest[] = {'O', 'N', 0, '\n'};
    check(CBVerbForData([NSData dataWithBytes:nulRequest length:sizeof(nulRequest)]) == nil, @"NUL request rejected");
    check(CBHashFromString(@"bad") == nil && CBHashFromString(@"gg112233445566778899aabbccddeeff00112233") == nil, @"malformed hash rejected");

    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    __block BOOL disabled = YES; // An unrelated global override exists initially.
    __block BOOL live = YES;
    __block BOOL failEnable = NO;
    __block BOOL failReset = NO;
    __block BOOL failMarker = NO;
    __block BOOL exitDuringEnable = NO;
    __block BOOL marker = NO;
    CBSleepLease *lease = [CBSleepLease new];
    lease.writeFlag = ^BOOL(BOOL value, NSString **error) {
        [actions addObject:value ? @"set1" : @"set0"];
        if((value && failEnable) || (!value && failReset))
        {
            if(value) { disabled = YES; } // A command can fail after taking effect.
            if(error != NULL) { *error = @"simulated power failure"; }
            return NO;
        }
        disabled = value;
        if(value && exitDuringEnable) { live = NO; }
        return YES;
    };
    lease.readFlag = ^NSNumber *(NSString **error) { (void)error; return @(disabled); };
    lease.createMarker = ^BOOL(NSString **error) {
        [actions addObject:@"create"];
        if(failMarker)
        {
            if(error != NULL) { *error = @"simulated marker failure"; }
            return NO;
        }
        marker = YES;
        return YES;
    };
    lease.removeMarker = ^BOOL(NSString **error) { (void)error; [actions addObject:@"remove"]; marker = NO; return YES; };
    lease.ownerIsLive = ^BOOL(audit_token_t token) { (void)token; return live; };
    audit_token_t owner = { .val = {501, 501, 20, 501, 20, 12345, 1, 98765} };
    audit_token_t other = owner;
    other.val[5]++;
    audit_token_t reusedPID = owner;
    reusedPID.val[7]++;
    NSDictionary *reply = [lease perform:@"STATUS" peer:owner];
    check([reply[@"ok"] boolValue] && ![reply[@"active"] boolValue] && actions.count == 0 && disabled, @"external override untouched");
    reply = [lease perform:@"BOGUS" peer:owner];
    check(![reply[@"ok"] boolValue] && [reply[@"error_code"] isEqual:@"protocol"] && actions.count == 0, @"invalid verb no side effects");
    reply = [lease perform:@"ON" peer:owner];
    check([reply[@"ok"] boolValue] && marker && disabled && [actions isEqual:@[@"create", @"set1"]], @"marker precedes enable");
    [lease perform:@"ON" peer:owner];
    check(actions.count == 2, @"ON is idempotent for owner");
    reply = [lease perform:@"ON" peer:other];
    check(![reply[@"ok"] boolValue] && [reply[@"error_code"] isEqual:@"ownership"] && actions.count == 2, @"overlapping app refused");
    reply = [lease perform:@"OFF" peer:reusedPID];
    check(![reply[@"ok"] boolValue] && lease.active && actions.count == 2, @"PID reuse cannot end lease");
    reply = [lease perform:@"OFF" peer:owner];
    check([reply[@"ok"] boolValue] && !lease.active && !marker && !disabled && [actions isEqual:@[@"create", @"set1", @"set0", @"remove"]], @"owner reset before marker removal");
    [actions removeAllObjects];
    [lease perform:@"ON" peer:owner];
    live = NO;
    [lease pollOwner];
    check(!lease.active && !disabled && !marker && [actions isEqual:@[@"create", @"set1", @"set0", @"remove"]], @"owner exit restores sleep");
    live = YES;
    failEnable = YES;
    [actions removeAllObjects];
    reply = [lease perform:@"ON" peer:owner];
    check(![reply[@"ok"] boolValue] && !lease.active && !marker && [actions isEqual:@[@"create", @"set1", @"set0", @"remove"]], @"failed enable rolls back");
    failEnable = NO;
    [actions removeAllObjects];
    failMarker = YES;
    reply = [lease perform:@"ON" peer:owner];
    check(![reply[@"ok"] boolValue] && !lease.active && !marker && [actions isEqual:@[@"create"]], @"marker failure cannot enable sleep override");
    failMarker = NO;
    [actions removeAllObjects];
    exitDuringEnable = YES;
    reply = [lease perform:@"ON" peer:owner];
    check(![reply[@"ok"] boolValue] && !lease.active && !marker && !disabled &&
          [actions isEqual:@[@"create", @"set1", @"set0", @"remove"]], @"owner exit during enable rolls back");
    exitDuringEnable = NO;
    live = YES;
    [actions removeAllObjects];
    [lease perform:@"ON" peer:owner];
    failReset = YES;
    reply = [lease perform:@"OFF" peer:owner];
    check(![reply[@"ok"] boolValue] && lease.active && marker && disabled, @"failed reset retains recovery marker");
    failReset = NO;
    [lease pollOwner];
    check(!lease.active && !marker && !disabled, @"failed reset retried while owner is still live");
    [actions removeAllObjects];
    lease.active = YES; // A valid durable marker was found on daemon restart.
    lease.owner = (audit_token_t){0};
    marker = YES;
    disabled = YES;
    [lease pollOwner];
    check(!lease.active && !marker && !disabled && [actions isEqual:@[@"set0", @"remove"]], @"daemon restart restores owned override");
    fprintf(stdout, "CoffeeBull helper self-test: %s (%lu failures)\n", failures == 0 ? "PASS" : "FAIL", (unsigned long)failures);
    return failures == 0 ? 0 : 1;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        if(argc == 2 && strcmp(argv[1], "--self-test") == 0) { return CBSelfTest(); }
        if(argc != 5 || strcmp(argv[1], "--uid") != 0 || strcmp(argv[3], "--cdhash") != 0 || geteuid() != 0)
        {
            fprintf(stderr, "CoffeeBull helper requires root and --uid <uid> --cdhash <40 hex characters>.\n");
            return 64;
        }
        errno = 0;
        char *end = NULL;
        unsigned long rawUID = strtoul(argv[2], &end, 10);
        NSData *approvedHash = CBHashFromString([NSString stringWithUTF8String:argv[4]]);
        if(errno != 0 || end == argv[2] || *end != '\0' || rawUID == 0 || rawUID >= UINT_MAX ||
           strspn(argv[2], "0123456789") != strlen(argv[2]) || approvedHash == nil)
        {
            fprintf(stderr, "CoffeeBull helper configuration is invalid.\n");
            return 64;
        }
        uid_t approvedUID = (uid_t)rawUID;
        umask(077);
        struct sigaction action = { .sa_handler = CBSignalHandler };
        sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGINT, &action, NULL);
        sigaction(SIGHUP, &action, NULL);
        CBSleepLease *lease = [CBSleepLease new];
        lease.writeFlag = ^BOOL(BOOL value, NSString **error) { return CBWriteSleepFlag(value, error); };
        lease.readFlag = ^NSNumber *(NSString **error) { return CBReadSleepFlag(error); };
        lease.createMarker = ^BOOL(NSString **error) { return CBCreateMarker(error); };
        lease.removeMarker = ^BOOL(NSString **error) { return CBRemoveMarker(error); };
        lease.ownerIsLive = ^BOOL(audit_token_t token) {
            char processPath[PROC_PIDPATHINFO_MAXSIZE];
            return proc_pidpath_audittoken(&token, processPath, sizeof(processPath)) > 0 &&
                CBValidateAuditToken(token, approvedUID, approvedHash);
        };
        NSString *error = nil;
        struct stat createdSocket = {0};
        // Refuse a second daemon before recovering an earlier daemon's marker.
        int listener = CBCreateListener(approvedUID, &createdSocket, &error);
        if(listener < 0) { NSLog(@"CoffeeBull: %@", error); return 73; }
        BOOL marker = NO;
        if(!CBMarkerPresent(&marker, &error))
        {
            NSLog(@"CoffeeBull: %@", error);
            close(listener);
            unlink(CBSocketPath);
            return 73;
        }
        if(marker) { lease.active = YES; [lease pollOwner]; }
        while(!CBShouldStop)
        {
            @autoreleasepool
            {
                [lease pollOwner];
                if(!CBWaitForSocket(listener, NO, CBMonotonicTime() + 0.25)) { continue; }
                int peer = accept(listener, NULL, NULL);
                if(peer < 0) { continue; }
                fcntl(peer, F_SETFD, FD_CLOEXEC);
                fcntl(peer, F_SETFL, O_NONBLOCK);
                int noSignal = 1;
                setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
                audit_token_t token;
                NSDictionary *reply;
                if(!CBAuthenticateSocket(peer, approvedUID, approvedHash, &token))
                {
                    reply = @{ @"ok": @NO, @"active": @NO, @"error": @"This app was not approved for the CoffeeBull helper.",
                               @"error_code": @"unauthorized", @"protocol": @2, @"owner_pid": @0 };
                }
                else
                {
                    NSString *verb = CBVerbForData(CBReadRequest(peer));
                    reply = [lease perform:verb peer:token];
                }
                CBWriteReply(peer, reply);
                close(peer);
                [lease pollOwner];
            }
        }
        // On graceful shutdown reset before returning. If the process is killed
        // or power is lost, the durable marker makes launchd's next run recover.
        for(NSUInteger attempt = 0; lease.active && attempt < 5; attempt++)
        {
            if([lease restore]) { break; }
            NSLog(@"CoffeeBull: %@", lease.lastError);
            usleep(250000);
        }
        close(listener);
        struct stat current;
        if(lstat(CBSocketPath, &current) == 0 && current.st_dev == createdSocket.st_dev &&
           current.st_ino == createdSocket.st_ino) { unlink(CBSocketPath); }
        return lease.active ? 74 : 0;
    }
}
