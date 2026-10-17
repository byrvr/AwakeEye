//
//  KYAMainMenu.m
//  KeepingYouAwake
//
//  Created by Marcel Dierkes on 12.02.22.
//  Copyright © 2022 Marcel Dierkes. All rights reserved.
//

#import "KYAMainMenu.h"
#import <KYACommon/KYACommon.h>
#import "KYALocalizedStrings.h"
#import "KYAAppDelegate.h"
#import "KYAAppController.h"

NSMenu *KYACreateMainMenuWithActivationDurationsSubMenu(NSMenu *activationDurationsSubMenu, id wakeModeTarget)
{
    NSCParameterAssert(activationDurationsSubMenu);
    NSCParameterAssert(wakeModeTarget);
    
    Auto mainMenu = [[NSMenu alloc] initWithTitle:@""];

    Auto wakeStatus = [[NSMenuItem alloc] initWithTitle:@"Coffee — Inactive"
                                                action:nil
                                         keyEquivalent:@""];
    wakeStatus.tag = KYAMainMenuItemTagWakeStatus;
    [mainMenu addItem:wakeStatus];

    Auto externalOverride = [[NSMenuItem alloc] initWithTitle:@"System Sleep Already Disabled"
                                                      action:nil
                                               keyEquivalent:@""];
    externalOverride.tag = KYAMainMenuItemTagExternalSleepOverride;
    externalOverride.hidden = YES;
    externalOverride.toolTip = @"Coffee does not change an existing macOS sleep override. Start and stop Red Bull to take ownership and restore normal sleep.";
    [mainMenu addItem:externalOverride];

    Auto modeMenu = [[NSMenu alloc] initWithTitle:@"Wake Mode"];
    Auto coffee = [[NSMenuItem alloc] initWithTitle:@"Coffee — Prevent Idle Sleep"
                                           action:@selector(selectCoffeeMode:)
                                    keyEquivalent:@""];
    coffee.target = wakeModeTarget;
    coffee.tag = KYAMainMenuItemTagCoffee;
    coffee.toolTip = @"Uses caffeinate while this app is running. Closing the lid still follows the Mac's sleep policy.";
    [modeMenu addItem:coffee];

    Auto redBull = [[NSMenuItem alloc] initWithTitle:@"Red Bull — Keep Running with Lid Closed"
                                            action:@selector(selectRedBullMode:)
                                     keyEquivalent:@""];
    redBull.target = wakeModeTarget;
    redBull.tag = KYAMainMenuItemTagRedBull;
    redBull.toolTip = @"One-time helper setup requires administrator approval. Toggles afterward do not ask. Disables lid and manual sleep on battery and power until stopped.";
    [modeMenu addItem:redBull];

    Auto wakeMode = [[NSMenuItem alloc] initWithTitle:@"Wake Mode"
                                              action:nil
                                       keyEquivalent:@""];
    wakeMode.tag = KYAMainMenuItemTagWakeMode;
    wakeMode.submenu = modeMenu;
    [mainMenu addItem:wakeMode];
    [mainMenu addItem:NSMenuItem.separatorItem];
    
    Auto activateForDuration = [[NSMenuItem alloc] initWithTitle:KYA_L10N_ACTIVATE_FOR_DURATION
                                                          action:nil
                                                   keyEquivalent:@""];
    if(@available(macOS 26.0, *))
    {
        activateForDuration.image = [NSImage imageWithSystemSymbolName:@"timer" accessibilityDescription:nil];
    }
    activateForDuration.submenu = activationDurationsSubMenu;
    [mainMenu addItem:activateForDuration];
    
    [mainMenu addItem:NSMenuItem.separatorItem];
    
    Auto settings = [[NSMenuItem alloc] initWithTitle:KYA_L10N_SETTINGS_ELLIPSIS
                                               action:@selector(showSettingsWindow:)
                                        keyEquivalent:@","];
    if(@available(macOS 26.0, *))
    {
        settings.image = [NSImage imageWithSystemSymbolName:@"gear" accessibilityDescription:nil];
    }
    [mainMenu addItem:settings];
    
    [mainMenu addItem:NSMenuItem.separatorItem];
    
    Auto quit = [[NSMenuItem alloc] initWithTitle:KYA_L10N_QUIT
                                           action:@selector(terminate:)
                                    keyEquivalent:@"q"];
    [mainMenu addItem:quit];
    
    return mainMenu;
}
