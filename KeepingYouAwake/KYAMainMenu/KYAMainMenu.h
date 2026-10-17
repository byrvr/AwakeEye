//
//  KYAMainMenu.h
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 12.02.22.
//  Copyright © 2022 Marcel Dierkes. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KYAMainMenuItemTag)
{
    KYAMainMenuItemTagWakeStatus = 1001,
    KYAMainMenuItemTagWakeMode,
    KYAMainMenuItemTagCoffee,
    KYAMainMenuItemTagRedBull,
    KYAMainMenuItemTagExternalSleepOverride
};

/// Creates a main menu with common commands like Quit, Settings… and the
/// activation durations and wake mode sub menus.
/// @param activationDurationsSubMenu An activation durations sub menu
/// @param wakeModeTarget The target for the Coffee and Red Bull mode actions
NSMenu *KYACreateMainMenuWithActivationDurationsSubMenu(NSMenu *activationDurationsSubMenu, id wakeModeTarget);

NS_ASSUME_NONNULL_END
