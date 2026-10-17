//
//  KYAAppController.h
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 17.10.14.
//  Copyright (c) 2014 Marcel Dierkes. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <KYASleepWakeTimer/KYASleepWakeTimer.h>
#import <KYADeviceInfo/KYADeviceInfo.h>
#import <KYAApplicationEvents/KYAApplicationEvents.h>
#import <KYAApplicationSupport/KYAApplicationSupport.h>
#import <KYAStatusItemUI/KYAStatusItemUI.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, KYAWakeMode)
{
    KYAWakeModeCoffee = 0,
    KYAWakeModeRedBull
};

@interface KYAAppController : NSObject

/// The associated KYASleepWakeTimer instance of this app controller.
@property (nonatomic, readonly) KYASleepWakeTimer *sleepWakeTimer;

/// Controls the display a action handling for the status bar item.
@property (nonatomic, readonly) KYAStatusItemController *statusItemController;

/// The mode selected for the next activation. A selection does not imply activation.
@property (nonatomic, readonly) KYAWakeMode wakeMode;

- (IBAction)selectCoffeeMode:(id)sender;
- (IBAction)selectRedBullMode:(id)sender;

@end

NS_ASSUME_NONNULL_END
