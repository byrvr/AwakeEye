//
//  KYAAppController.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import "KYAAppController.h"
#import <KYACommon/KYACommon.h>
#import "KYALocalizedStrings.h"
#import "KYAMainMenu.h"
#import "KYABatteryCapacityThreshold.h"
#import "KYAActivationDurationsMenuController.h"
#import "KYAActivationUserNotification.h"
#import "../KYAClosedLidSession.h"
#import <IOKit/IOKitLib.h>

// Deprecated!
#define KYA_MINUTES(m) (m * 60.0f)
#define KYA_HOURS(h) (h * 3600.0f)

static BOOL KYASystemSleepIsDisabled(void)
{
    io_service_t rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if(rootDomain == IO_OBJECT_NULL)
    {
        return NO;
    }

    id sleepDisabled = CFBridgingRelease(IORegistryEntryCreateCFProperty(rootDomain, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0));
    IOObjectRelease(rootDomain);
    return [sleepDisabled respondsToSelector:@selector(boolValue)] && [sleepDisabled boolValue];
}

@interface KYAAppController () <KYAStatusItemControllerDataSource, KYAStatusItemControllerDelegate, KYAActivationDurationsMenuControllerDelegate, KYASleepWakeTimerDelegate>
@property (nonatomic, readwrite) KYASleepWakeTimer *sleepWakeTimer;
@property (nonatomic, readwrite) KYAStatusItemController *statusItemController;
@property (nonatomic, readwrite) KYAWakeMode wakeMode;
@property (nonatomic) KYAClosedLidSession *closedLidSession;
@property (nonatomic, nullable) NSError *closedLidCleanupError;
@property (nonatomic) BOOL cleanupErrorAlertScheduled;
@property (nonatomic) BOOL cleanupErrorAlertPresented;
@property (nonatomic) BOOL authorizingRedBull;
@property (nonatomic) BOOL terminating;
@property (nonatomic) KYAActivationDurationsMenuController *menuController;

@property (nonatomic) NSTimeInterval workspaceScheduledTimeInterval;

// Battery Status
@property (nonatomic, direct, getter=isBatteryOverrideEnabled) BOOL batteryOverrideEnabled;

// Menu
@property (nonatomic) NSMenu *menu;
@end

@implementation KYAAppController

#pragma mark - Life Cycle

- (instancetype)init
{
    self = [super init];
    if(self)
    {
        self.wakeMode = KYAWakeModeCoffee;
        self.workspaceScheduledTimeInterval = -1;
        self.closedLidSession = [KYAClosedLidSession new];

        [self configureStatusItemController];
        [self configureSleepWakeTimer];
        [self configureEventHandler];
        [self configureUserNotificationCenter];
        [self configureMainMenu];

        Auto center = NSNotificationCenter.defaultCenter;
        [center addObserver:self
                   selector:@selector(applicationWillFinishLaunching:)
                       name:NSApplicationWillFinishLaunchingNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(applicationDidChangeScreenParameters:)
                       name:NSApplicationDidChangeScreenParametersNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(batteryCapacityThresholdDidChange:)
                       name:kKYABatteryCapacityThresholdDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(applicationWillTerminate:)
                       name:NSApplicationWillTerminateNotification
                     object:nil];
        
        [self registerForWorkspaceSessionNotifications];

        // Always launch in Coffee mode, without an administrator prompt.
        if([NSUserDefaults.standardUserDefaults kya_isActivatedOnLaunch])
        {
            [self activateTimer];
        }
    }
    return self;
}

- (void)dealloc
{
    [self.closedLidSession endSession];
    Auto center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSApplicationWillFinishLaunchingNotification object:nil];
    [center removeObserver:self name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [center removeObserver:self name:kKYABatteryCapacityThresholdDidChangeNotification object:nil];
    [center removeObserver:self name:NSApplicationWillTerminateNotification object:nil];
    
    [self unregisterFromWorkspaceSessionNotifications];
}

#pragma mark - Main Menu

- (void)configureMainMenu
{
    Auto menuController = [KYAActivationDurationsMenuController new];
    menuController.delegate = self;
    self.menuController = menuController;
    
    self.menu = KYACreateMainMenuWithActivationDurationsSubMenu(menuController.menu, self);
    [self updateWakeModeAppearance];
}

#pragma mark - Wake Modes

- (IBAction)selectCoffeeMode:(id)sender
{
    [self selectWakeMode:KYAWakeModeCoffee];
}

- (IBAction)selectRedBullMode:(id)sender
{
    [self selectWakeMode:KYAWakeModeRedBull];
}

- (void)selectWakeMode:(KYAWakeMode)wakeMode
{
    if(self.wakeMode == wakeMode && [self.sleepWakeTimer isScheduled] &&
       (wakeMode == KYAWakeModeCoffee || self.closedLidSession.active))
    {
        return;
    }

    KYAWakeMode previousMode = self.wakeMode;
    BOOL wasScheduled = [self.sleepWakeTimer isScheduled];
    Auto fireDate = self.sleepWakeTimer.fireDate;
    NSTimeInterval remainingTime = wasScheduled ? KYASleepWakeTimeIntervalIndefinite : self.defaultTimeInterval;
    if(wasScheduled && fireDate != nil)
    {
        remainingTime = MAX(0, fireDate.timeIntervalSinceNow);
    }

    [self terminateTimer];
    self.wakeMode = wakeMode;
    [self updateWakeModeAppearance];

    // An already expired timed session must not become an indefinite session.
    if(wasScheduled && fireDate != nil && remainingTime <= 0)
    {
        return;
    }

    if([self activateTimerWithTimeInterval:remainingTime deadline:fireDate] == NO && wasScheduled)
    {
        // Cancelling the administrator prompt keeps the previous mode running.
        self.wakeMode = previousMode;
        if(fireDate != nil)
        {
            remainingTime = MAX(0, fireDate.timeIntervalSinceNow);
            if(remainingTime <= 0)
            {
                [self updateWakeModeAppearance];
                return;
            }
        }
        [self activateTimerWithTimeInterval:remainingTime deadline:fireDate];
    }
}

- (void)updateWakeModeAppearance
{
    BOOL active = [self.sleepWakeTimer isScheduled] &&
        (self.wakeMode == KYAWakeModeCoffee || self.closedLidSession.active);
    Auto modeName = self.wakeMode == KYAWakeModeRedBull ? @"Red Bull" : @"Coffee";
    self.statusItemController.appearance = active ? KYAStatusItemAppearanceActive : KYAStatusItemAppearanceInactive;
    Auto statusItem = [self.menu itemWithTag:KYAMainMenuItemTagWakeStatus];
    statusItem.title = [NSString stringWithFormat:@"AwakeEye · %@ — %@", modeName, active ? @"Active" : @"Inactive"];
    if(self.closedLidCleanupError != nil)
    {
        statusItem.title = self.wakeMode == KYAWakeModeCoffee && active
            ? @"AwakeEye · Coffee Active — Sleep Restore Failed"
            : @"AwakeEye · Sleep Restore Failed";
    }

    BOOL externalSleepOverride = self.wakeMode == KYAWakeModeCoffee && KYASystemSleepIsDisabled();
    Auto overrideItem = [self.menu itemWithTag:KYAMainMenuItemTagExternalSleepOverride];
    overrideItem.hidden = !externalSleepOverride && self.closedLidCleanupError == nil;
    overrideItem.title = self.closedLidCleanupError != nil ? @"Normal Sleep Needs Recovery" : @"System Sleep Already Disabled";
    overrideItem.toolTip = self.closedLidCleanupError.localizedDescription ?: @"Coffee does not change an existing macOS sleep override. Start and stop Red Bull to take ownership and restore normal sleep.";

    Auto modeMenu = [self.menu itemWithTag:KYAMainMenuItemTagWakeMode].submenu;
    [modeMenu itemWithTag:KYAMainMenuItemTagCoffee].state = self.wakeMode == KYAWakeModeCoffee ? NSControlStateValueOn : NSControlStateValueOff;
    [modeMenu itemWithTag:KYAMainMenuItemTagRedBull].state = self.wakeMode == KYAWakeModeRedBull ? NSControlStateValueOn : NSControlStateValueOff;

    Auto button = self.statusItemController.systemStatusItem.button;
    if(@available(macOS 11.0, *))
    {
        AutoVar symbolName = self.wakeMode == KYAWakeModeRedBull
            ? (active ? @"eye.circle.fill" : @"eye.slash")
            : (active ? @"eye" : @"eye.slash");
        if(self.closedLidCleanupError != nil) { symbolName = @"exclamationmark.triangle.fill"; }
        Auto image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:modeName];
        if(image != nil)
        {
            image.template = YES;
            button.image = image;
        }
    }
    if(self.wakeMode == KYAWakeModeRedBull)
    {
        button.toolTip = active
            ? @"Red Bull active — lid and manual sleep disabled systemwide, including on battery. Click to stop."
            : @"Red Bull selected — click to keep the Mac awake with the lid closed.";
    }
    else
    {
        if(externalSleepOverride)
        {
            button.toolTip = active
                ? @"Coffee active — a separate system sleep override is also active. Click to stop Coffee."
                : @"Coffee selected — system sleep is already disabled by a separate override. Click to start Coffee.";
        }
        else
        {
            button.toolTip = active
                ? @"Coffee active — prevents idle sleep. Click to stop."
                : @"Coffee selected — click to prevent idle sleep.";
        }
    }
    if(self.closedLidCleanupError != nil)
    {
        button.toolTip = self.closedLidCleanupError.localizedDescription;
    }
}

// Record cleanup failures independently of the timer's active state. Alerts are
// deferred until the current mode/timer transition has finished, and shown once
// per failure episode. They never interrupt application termination.
- (void)endClosedLidSession
{
    [self.closedLidSession endSession];
    self.closedLidCleanupError = self.closedLidSession.lastCleanupError;
    if(self.closedLidCleanupError == nil)
    {
        self.cleanupErrorAlertPresented = NO;
        return;
    }
    if(self.terminating || self.cleanupErrorAlertPresented || self.cleanupErrorAlertScheduled) { return; }

    self.cleanupErrorAlertScheduled = YES;
    AutoWeak weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        Auto strongSelf = weakSelf;
        if(strongSelf == nil) { return; }
        strongSelf.cleanupErrorAlertScheduled = NO;
        if(strongSelf.terminating || strongSelf.authorizingRedBull || strongSelf.closedLidCleanupError == nil || strongSelf.cleanupErrorAlertPresented) { return; }
        strongSelf.cleanupErrorAlertPresented = YES;
        Auto alert = [NSAlert new];
        alert.messageText = @"Normal Sleep Could Not Be Restored";
        alert.informativeText = [strongSelf.closedLidCleanupError.localizedDescription stringByAppendingString:@"\n\nQuit all AwakeEye instances before following the sleep recovery instructions. Red Bull cannot start until its previous session has finished cleanup."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    });
}

#pragma mark - Status Item Controller

- (void)configureStatusItemController
{
    Auto statusItemController = [KYAStatusItemController new];
    statusItemController.dataSource = self;
    statusItemController.delegate = self;
    self.statusItemController = statusItemController;
}

#pragma mark - Sleep Wake Timer

- (void)configureSleepWakeTimer
{
    Auto sleepWakeTimer = [KYASleepWakeTimer new];
    sleepWakeTimer.delegate = self;
    self.sleepWakeTimer = sleepWakeTimer;
}

- (BOOL)activateTimer
{
    return [self activateTimerWithTimeInterval:self.defaultTimeInterval];
}

- (BOOL)activateTimerWithTimeInterval:(NSTimeInterval)timeInterval
{
    return [self activateTimerWithTimeInterval:timeInterval deadline:nil];
}

- (BOOL)activateTimerWithTimeInterval:(NSTimeInterval)timeInterval deadline:(nullable NSDate *)deadline
{
    // Do not allow negative time intervals
    if(timeInterval < 0 || (deadline != nil && deadline.timeIntervalSinceNow <= 0))
    {
        return NO;
    }

    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }

    // Replace the old timer before authorization can spin a nested run loop.
    // A previous session's queued callbacks must never affect the new session.
    self.sleepWakeTimer.delegate = nil;
    Auto sleepWakeTimer = [KYASleepWakeTimer new];
    sleepWakeTimer.delegate = self;
    self.sleepWakeTimer = sleepWakeTimer;

    if(self.wakeMode == KYAWakeModeRedBull)
    {
        NSError *error = nil;
        self.authorizingRedBull = YES;
        BOOL started = [self.closedLidSession beginSessionWithError:&error];
        self.authorizingRedBull = NO;
        if(started == NO)
        {
            self.closedLidCleanupError = self.closedLidSession.lastCleanupError;
            [self updateWakeModeAppearance];
            if(error != nil && error.code != NSUserCancelledError &&
               (self.closedLidCleanupError == nil || !self.cleanupErrorAlertPresented))
            {
                if(self.closedLidCleanupError != nil) { self.cleanupErrorAlertPresented = YES; }
                Auto alert = [NSAlert new];
                alert.messageText = @"Red Bull Could Not Start";
                alert.informativeText = error.localizedDescription;
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
            }
            return NO;
        }
        self.closedLidCleanupError = nil;
        self.cleanupErrorAlertPresented = NO;
    }

    if(deadline != nil)
    {
        // Time spent authorizing Red Bull counts toward an existing session.
        timeInterval = deadline.timeIntervalSinceNow;
        if(timeInterval <= 0)
        {
            [self endClosedLidSession];
            [self updateWakeModeAppearance];
            return NO;
        }
    }

    Auto defaults = NSUserDefaults.standardUserDefaults;
    AutoWeak weakSelf = self;
    AutoWeak weakTimer = sleepWakeTimer;
    Auto timerCompletion = ^(BOOL cancelled) {
        Auto strongSelf = weakSelf;
        if(cancelled || strongSelf == nil || strongSelf.sleepWakeTimer != weakTimer)
        {
            return;
        }
        [strongSelf endClosedLidSession];
        [strongSelf disableBatteryOverride];
        [strongSelf updateWakeModeAppearance];

        // Post deactivation notification
        Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:nil activating:NO];
        [KYAUserNotificationCenter.sharedCenter postNotification:notification];

        // Quit on timer expiration
        if(cancelled == NO && [defaults kya_isQuitOnTimerExpirationEnabled])
        {
            [NSApplication.sharedApplication terminate:nil];
        }
    };
    [self.sleepWakeTimer scheduleWithTimeInterval:timeInterval completion:timerCompletion];
    [self updateWakeModeAppearance];

    // Post activation notification
    Auto fireDate = self.sleepWakeTimer.fireDate;
    Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:fireDate activating:YES];
    [KYAUserNotificationCenter.sharedCenter postNotification:notification];
    return YES;
}

- (void)terminateTimer
{
    BOOL wasActive = [self.sleepWakeTimer isScheduled] || self.closedLidSession.active;
    [self endClosedLidSession];
    [self disableBatteryOverride];

    if([self.sleepWakeTimer isScheduled])
    {
        [self.sleepWakeTimer invalidate];
    }
    [self disableDevicePowerMonitoring];
    [self updateWakeModeAppearance];

    if(wasActive)
    {
        Auto notification = [[KYAActivationUserNotification alloc] initWithFireDate:nil activating:NO];
        [KYAUserNotificationCenter.sharedCenter postNotification:notification];
    }
}

#pragma mark - Default Time Interval

- (NSTimeInterval)defaultTimeInterval
{
    return NSUserDefaults.standardUserDefaults.kya_defaultTimeInterval;
}

#pragma mark - Activate on Launch

- (IBAction)toggleActivateOnLaunch:(id)sender
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    defaults.kya_activateOnLaunch = ![defaults kya_isActivatedOnLaunch];
    [defaults synchronize];
}

#pragma mark - User Notification Center

- (void)configureUserNotificationCenter
{
    Auto center = KYAUserNotificationCenter.sharedCenter;
    [center requestAuthorizationIfUndetermined];
    [center clearAllDeliveredNotifications];
}

#pragma mark - Device Power Monitoring

- (void)checkAndEnableBatteryOverride
{
    Auto batteryMonitor = KYADevice.currentDevice.batteryMonitor;
    CGFloat currentCapacity = batteryMonitor.currentCapacity;
    CGFloat threshold = NSUserDefaults.standardUserDefaults.kya_batteryCapacityThreshold;

    self.batteryOverrideEnabled = (currentCapacity <= threshold);
}

- (void)disableBatteryOverride
{
    self.batteryOverrideEnabled = NO;
}

- (void)deviceParameterDidChange:(NSNotification *)notification
{
    NSParameterAssert(notification);
    
    Auto device = (KYADevice *)notification.object;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    Auto userInfo = notification.userInfo;
    Auto deviceParameter = (KYADeviceParameter)userInfo[KYADeviceParameterKey];
    if([deviceParameter isEqualToString:KYADeviceParameterBattery])
    {
        if([defaults kya_isBatteryCapacityThresholdEnabled] == NO) { return; }
        
        CGFloat threshold = defaults.kya_batteryCapacityThreshold;
        Auto capacity = device.batteryMonitor.currentCapacity;
        if([self.sleepWakeTimer isScheduled] && (capacity <= threshold) && ![self isBatteryOverrideEnabled])
        {
            [self terminateTimer];
        }
    }
    else if([deviceParameter isEqualToString:KYADeviceParameterLowPowerMode])
    {
        if([defaults kya_isLowPowerModeMonitoringEnabled] == NO) { return; }
        
        if([device.lowPowerModeMonitor isLowPowerModeEnabled] && [self.sleepWakeTimer isScheduled])
        {
            [self terminateTimer];
        }
    }
}

- (void)enableDevicePowerMonitoring
{
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    Auto defaults = NSUserDefaults.standardUserDefaults;
    
    // Check battery overrides and register for capacity changes.
    [self checkAndEnableBatteryOverride];
    
    [center addObserver:self
               selector:@selector(deviceParameterDidChange:)
                   name:KYADeviceParameterDidChangeNotification
                 object:device];
    
    if([defaults kya_isBatteryCapacityThresholdEnabled])
    {
        device.batteryMonitoringEnabled = YES;
    }
    if([defaults kya_isLowPowerModeMonitoringEnabled])
    {
        device.lowPowerModeMonitoringEnabled = YES;
    }
}

- (void)disableDevicePowerMonitoring
{
    Auto device = KYADevice.currentDevice;
    Auto center = NSNotificationCenter.defaultCenter;
    
    [center removeObserver:self
                      name:KYADeviceParameterDidChangeNotification
                    object:device];
    
    device.batteryMonitoringEnabled = NO;
    device.lowPowerModeMonitoringEnabled = NO;
}

#pragma mark - Battery Capacity Threshold Changes

- (void)batteryCapacityThresholdDidChange:(NSNotification *)notification
{
    if([self.sleepWakeTimer isScheduled])
    {
        [self terminateTimer];
    }
}

#pragma mark - Workspace Session Handling

- (void)registerForWorkspaceSessionNotifications
{
    Auto workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter addObserver:self
                        selector:@selector(workspaceSessionDidBecomeActive:)
                            name:NSWorkspaceSessionDidBecomeActiveNotification
                          object:nil];
    [workspaceCenter addObserver:self
                        selector:@selector(workspaceSessionDidResignActive:)
                            name:NSWorkspaceSessionDidResignActiveNotification
                          object:nil];
}

- (void)unregisterFromWorkspaceSessionNotifications
{
    Auto workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
    [workspaceCenter removeObserver:self
                               name:NSWorkspaceSessionDidBecomeActiveNotification
                             object:nil];
    [workspaceCenter removeObserver:self
                               name:NSWorkspaceSessionDidResignActiveNotification
                             object:nil];
}

- (void)workspaceSessionDidBecomeActive:(NSNotification *)notification
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    if([defaults kya_isDeactivateOnUserSwitchEnabled] && self.workspaceScheduledTimeInterval >= 0)
    {
        [self activateTimerWithTimeInterval:self.workspaceScheduledTimeInterval];
        self.workspaceScheduledTimeInterval = -1;
    }
}

- (void)workspaceSessionDidResignActive:(NSNotification *)notification
{
    Auto defaults = NSUserDefaults.standardUserDefaults;
    if([defaults kya_isDeactivateOnUserSwitchEnabled] && [self.sleepWakeTimer isScheduled])
    {
        Auto fireDate = self.sleepWakeTimer.fireDate;
        self.workspaceScheduledTimeInterval = fireDate == nil
            ? KYASleepWakeTimeIntervalIndefinite
            : MAX(0, fireDate.timeIntervalSinceNow);
        if(fireDate != nil && self.workspaceScheduledTimeInterval <= 0)
        {
            self.workspaceScheduledTimeInterval = -1;
        }
        [self terminateTimer];
    }
}

#pragma mark - Event Handling

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    [KYAEventHandler.defaultHandler registerAsDefaultEventHandler];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    self.terminating = YES;
    [self terminateTimer];
}

- (void)configureEventHandler
{
    Auto eventHandler = KYAEventHandler.defaultHandler;
    
    AutoWeak weakSelf = self;
    [eventHandler registerActionNamed:@"redbull" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        [strongSelf selectRedBullMode:strongSelf];
    }];
    [eventHandler registerActionNamed:@"coffee" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        [strongSelf selectCoffeeMode:strongSelf];
    }];

    [eventHandler registerActionNamed:@"activate" block:^(KYAEvent *event) {
        [weakSelf handleActivateActionForEvent:event];
    }];
    
    [eventHandler registerActionNamed:@"deactivate" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        [strongSelf terminateTimer];
    }];
    
    [eventHandler registerActionNamed:@"toggle" block:^(KYAEvent *event) {
        Auto strongSelf = weakSelf;
        [strongSelf statusItemControllerShouldPerformPrimaryAction:strongSelf.statusItemController];
    }];
}

- (void)handleActivateActionForEvent:(KYAEvent *)event
{
    Auto parameters = event.arguments;
    NSString *seconds = parameters[@"seconds"];
    NSString *minutes = parameters[@"minutes"];
    NSString *hours = parameters[@"hours"];

    [self terminateTimer];
    
    // Activate indefinitely if there are no parameters
    if(parameters == nil || parameters.count == 0)
    {
        [self activateTimer];
    }
    else if(seconds != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)ceil(seconds.doubleValue)];
    }
    else if(minutes != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_MINUTES(ceil(minutes.doubleValue))];
    }
    else if(hours != nil)
    {
        [self activateTimerWithTimeInterval:(NSTimeInterval)KYA_HOURS(ceil(hours.doubleValue))];
    }
    else
    {
        [self updateWakeModeAppearance];
    }
}

#pragma mark - Internal / External Screen Parameter Changes

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
    if([NSUserDefaults.standardUserDefaults kya_isActivateOnExternalDisplayConnectedEnabled] == NO)
    {
        return;
    }
    
    NSUInteger numberOfExternalScreens = KYADisplayParametersGetNumberOfExternalDisplays();
    Auto sleepWakeTimer = self.sleepWakeTimer;
    
    if(numberOfExternalScreens == 0)
    {
        // Only the main screen is connected, deactivate!
        if([sleepWakeTimer isScheduled])
        {
            [self terminateTimer];
        }
    }
    else
    {
        // The main screen and at least one external screen, activate!
        if([sleepWakeTimer isScheduled] == NO)
        {
            [self activateTimer];
        }
    }
}

#pragma mark - KYAStatusItemControllerDataSource

- (NSMenu *)menuForStatusItemController:(KYAStatusItemController *)controller
{
    [self updateWakeModeAppearance];
    return self.menu;
}

#pragma mark - KYAStatusItemControllerDelegate

- (void)statusItemControllerShouldPerformPrimaryAction:(KYAStatusItemController *)controller
{
    if([self.sleepWakeTimer isScheduled] &&
       (self.wakeMode == KYAWakeModeCoffee || self.closedLidSession.active))
    {
        [self terminateTimer];
    }
    else
    {
        [self activateTimer];
    }
}

#pragma mark - KYAActivationDurationsMenuControllerDelegate

- (KYAActivationDuration *)currentActivationDuration
{
    Auto sleepWakeTimer = self.sleepWakeTimer;
    if(![sleepWakeTimer isScheduled])
    {
        return nil;
    }

    NSTimeInterval seconds = sleepWakeTimer.scheduledTimeInterval;
    return [[KYAActivationDuration alloc] initWithSeconds:seconds];
}

- (void)activationDurationsMenuController:(KYAActivationDurationsMenuController *)controller didSelectActivationDuration:(KYAActivationDuration *)activationDuration
{
    [self terminateTimer];

    AutoWeak weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimeInterval seconds = activationDuration.seconds;
        [weakSelf activateTimerWithTimeInterval:seconds];
    });
}

- (NSDate *)fireDateForMenuController:(KYAActivationDurationsMenuController *)controller
{
    return self.sleepWakeTimer.fireDate;
}

#pragma mark - KYASleepWakeTimerDelegate

- (void)sleepWakeTimer:(KYASleepWakeTimer *)sleepWakeTimer willActivateWithTimeInterval:(NSTimeInterval)timeInterval
{
    if(sleepWakeTimer != self.sleepWakeTimer)
    {
        return;
    }
    // Update the status item
    self.statusItemController.appearance = KYAStatusItemAppearanceActive;
    
    [self enableDevicePowerMonitoring];
}

- (void)sleepWakeTimerDidDeactivate:(KYASleepWakeTimer *)sleepWakeTimer
{
    if(sleepWakeTimer != self.sleepWakeTimer || [sleepWakeTimer isScheduled])
    {
        return;
    }

    [self endClosedLidSession];
    [self updateWakeModeAppearance];
    
    [self disableDevicePowerMonitoring];
}

@end
