// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface FXRootListController : PSListController
@end

@implementation FXRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// Files and the picker service are sandboxed and read the settings from the plist file. cfprefsd writes
// that file on its own schedule, often after the change notification has been handled, so the file is
// also written here before the notification is posted.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", domain];
    NSDictionary *all = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSMutableDictionary *file = [all mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) file[key] = value; else [file removeObjectForKey:key];
    [file writeToFile:path atomically:YES];
    NSString *note = [specifier propertyForKey:@"PostNotification"];
    if (note.length) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)note, NULL, NULL, YES);
}

@end
