#import <Foundation/Foundation.h>
#import "../KeepingYouAwake/KYAClosedLidSession.m"

// Generate the production watchdog with only its effectful commands and paths
// replaced. Running this helper never executes AppleScript or requests root.
int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        if(argc != 2) { return 2; }
        NSString *testRoot = [NSString stringWithUTF8String:argv[1]];
        NSString *script = KYAPrivilegedLauncherScript(4242, @"lease identity ' quoted $() ; harmless");
        NSDictionary<NSString *, NSString *> *replacements = @{
            @"/usr/bin/pmset": KYAShellQuotedString([testRoot stringByAppendingPathComponent:@"pmset"]),
            @"/usr/bin/caffeinate": KYAShellQuotedString([testRoot stringByAppendingPathComponent:@"caffeinate"]),
            @"/bin/ps": KYAShellQuotedString([testRoot stringByAppendingPathComponent:@"ps"]),
            @"/usr/bin/logger": @"/usr/bin/true",
            @"/private/tmp/keepingyouawake-redbull.lock": KYAShellQuotedString([testRoot stringByAppendingPathComponent:@"lock"]),
            @"/private/tmp/keepingyouawake-redbull.XXXXXXXX": KYAShellQuotedString([testRoot stringByAppendingPathComponent:@"status.XXXXXXXX"])
        };
        for(NSString *command in replacements)
        {
            script = [script stringByReplacingOccurrencesOfString:command withString:replacements[command]];
        }
        printf("%s", script.UTF8String);
    }
    return 0;
}
