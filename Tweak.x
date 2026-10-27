// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesExtensions 1.0.1
// Controls whether the Files app (iOS 12) shows file name extensions. Display only: no file is renamed.
//
// Where iOS 12 hides extensions (FileProvider.framework, in the dyld shared cache):
//   -[FPItem displayName]
//       return _displayName ?: [_filename fp_displayNameFromFilenameOfFolder:self.isFolder];
//   -[NSString(FPAdditions) fp_displayNameFromFilenameOfFolder:]
//       files:   [self stringByDeletingPathExtension], then ":" -> "/"
//       folders: ":" -> "/"
// So for files, iOS 12 drops the last extension whatever it is (".txt", ".dylib", ".ios", ".tvos"...),
// which is why patch_dyld.ios / .tvos / .bridgeos all look like "patch_dyld". The names Files draws
// come from -[FPItem displayName]: list and icon cells, Recents, Search, the rename field and the sort
// order (the Info sheet title is the exception, see below). The same FPItem class is used by Files, by
// the document picker / "Save to Files" service that other apps show
// (com.apple.DocumentManagerUICore.Service) and by the Files recents popover in the Dock, so one hook
// covers all of them and every location (On My iPad, iCloud Drive, FilesRoot's System location,
// third-party providers).
//
// Rename: Files passes the text typed in the name field to -[FPRenameOperation initWithItem:newName:],
// which treats it as a display name and re-appends the old extension:
//   _newName = [newName fp_filenameFromDisplayNameWithExtension:(isFolder ? nil : filename.pathExtension)]
// When the extension was shown in the field (or the user typed it back), we store the typed name as is
// (only "/" -> ":", as iOS does), so "a.txt" -> "b.txt" gives b.txt and "a.txt" -> "b" gives b.
//
// Info sheet: -[DOCItemInfoViewController updatePrimaryTitleWithItem:] (DocumentManagerUICore) always
// shows displayName + "." + filename.pathExtension for files, so iOS's Info title has the extension
// even when the list hides it. With the extension already in displayName that would read "b.tar.gz.gz",
// so the title is set to the plain filename when we show the extension.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreServices/UTType.h>
#import <CoreServices/UTCoreTypes.h>
#import <objc/runtime.h>
#include <notify.h>

#define kFXDomain CFSTR("com.itsallexb.filesextensions")
#define kFXNotification "com.itsallexb.filesextensions/prefschanged"
static NSString *const kFXPrefsPath = @"/var/mobile/Library/Preferences/com.itsallexb.filesextensions.plist";
static NSString *const kFXSystemProviderID = @"com.itsallexb.filesroot.provider";   // FilesRoot's "System"

typedef NS_ENUM(NSInteger, FXMode) {
    FXModeDefault = 0,   // iOS 12 behaviour: drop the last extension of every file
    FXModeShowAll,       // show every extension
    FXModeHideKnown,     // hide only extensions iOS knows a file type for; show the rest (".ios", ".tvos"...)
};

@interface FPItem : NSObject
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, readonly) NSString *providerIdentifier;
@property (nonatomic, readonly) BOOL isFolder;
@end

@interface DOCItemInfoViewController : UIViewController
- (UILabel *)primaryLabel;
@end

@interface NSString (FXFileProvider)
- (NSString *)fp_displayNameFromFilenameOfFolder:(BOOL)folder;
- (NSString *)fp_filenameFromDisplayNameWithExtension:(NSString *)extension;
@end

#pragma mark - Preferences

static BOOL gEnabled = YES;
static FXMode gMode = FXModeShowAll;
static BOOL gAlwaysSystem = YES;
static NSObject *gLock;

// Files and the picker service are sandboxed and cfprefsd may refuse them another app's domain, or hand
// them a stale copy, so the plist the settings pane writes (before it posts the notification) is read
// directly; CFPreferences is only the fallback when there is no file yet.
static id FXValue(NSDictionary *file, CFStringRef key) {
    if (file) return file[(__bridge NSString *)key];
    return CFBridgingRelease(CFPreferencesCopyAppValue(key, kFXDomain));
}

// Returns YES if a setting changed.
static BOOL FXLoadPrefs(void) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:kFXPrefsPath];
    if (!file) CFPreferencesAppSynchronize(kFXDomain);
    id en = FXValue(file, CFSTR("enabled"));
    id mode = FXValue(file, CFSTR("mode"));
    id sys = FXValue(file, CFSTR("alwaysShowSystem"));
    FXMode m = FXModeShowAll;
    if ([mode isKindOfClass:[NSString class]]) {
        if ([mode isEqualToString:@"default"]) m = FXModeDefault;
        else if ([mode isEqualToString:@"known"]) m = FXModeHideKnown;
    }
    BOOL e = [en respondsToSelector:@selector(boolValue)] ? [en boolValue] : YES;
    BOOL a = [sys respondsToSelector:@selector(boolValue)] ? [sys boolValue] : YES;
    BOOL changed;
    @synchronized (gLock) {
        changed = e != gEnabled || m != gMode || a != gAlwaysSystem;
        gEnabled = e;
        gMode = m;
        gAlwaysSystem = a;
    }
    return changed;
}

#pragma mark - Decision

// YES if iOS has a real (non-dynamic) file type for this extension, e.g. txt, pdf, jpg, dylib, gz.
static BOOL FXIsKnownExtension(NSString *ext) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = ext.lowercaseString;
    NSNumber *hit = [cache objectForKey:key];
    if (hit) return hit.boolValue;
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)key, NULL);
    BOOL known = uti && !UTTypeIsDynamic(uti);
    if (uti) CFRelease(uti);
    [cache setObject:@(known) forKey:key];
    return known;
}

// Whether the extension of this item's filename is shown. NO for folders and names without an
// extension (NSString does not treat the dot of ".hidden" as one).
static BOOL FXShowsExtension(FPItem *item, NSString *filename) {
    BOOL enabled; FXMode mode; BOOL alwaysSystem;
    @synchronized (gLock) { enabled = gEnabled; mode = gMode; alwaysSystem = gAlwaysSystem; }
    if (!enabled || item.isFolder || !filename.pathExtension.length) return NO;
    if (alwaysSystem && [item.providerIdentifier isEqualToString:kFXSystemProviderID]) return YES;
    switch (mode) {
        case FXModeShowAll:   return YES;
        case FXModeHideKnown: return !FXIsKnownExtension(filename.pathExtension);
        default:              return NO;
    }
}

static NSString *FXFullDisplayName(NSString *filename) {
    return [filename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
}

static NSString *FXFilenameFromTyped(NSString *typed) {
    return [typed stringByReplacingOccurrencesOfString:@"/" withString:@":"];
}

#pragma mark - Hooks

%hook FPItem

- (NSString *)displayName {
    NSString *orig = %orig;
    NSString *filename = self.filename;
    if (![filename isKindOfClass:[NSString class]] || !filename.length) return orig;
    if (FXShowsExtension(self, filename)) return FXFullDisplayName(filename);
    return orig;
}

%end

%hook FPRenameOperation

- (id)initWithItem:(FPItem *)item newName:(NSString *)newName {
    id op = %orig;
    if (!op || ![newName isKindOfClass:[NSString class]] || !newName.length) return op;
    BOOL enabled;
    @synchronized (gLock) { enabled = gEnabled; }
    if (!enabled || item.isFolder) return op;
    NSString *filename = item.filename;
    NSString *ext = filename.pathExtension;
    if (!ext.length) return op;   // nothing was hidden, iOS appends nothing
    // Keep the typed name as is when the field showed the extension, or when the user typed the
    // hidden extension back in (iOS would turn "b.txt" into "b.txt.txt").
    BOOL verbatim = FXShowsExtension(item, filename)
        || [newName.pathExtension caseInsensitiveCompare:ext] == NSOrderedSame;
    if (!verbatim) return op;
    Ivar iv = class_getInstanceVariable(object_getClass(op), "_newName");
    if (!iv) return op;
    __strong NSString **slot = (__strong NSString **)(void *)((uint8_t *)(__bridge void *)op + ivar_getOffset(iv));
    *slot = FXFilenameFromTyped(newName);
    return op;
}

%end

%hook DOCItemInfoViewController

- (void)updatePrimaryTitleWithItem:(FPItem *)item {
    %orig;
    if (![item isKindOfClass:%c(FPItem)] || ![self respondsToSelector:@selector(primaryLabel)]) return;
    NSString *filename = item.filename;
    if ([filename isKindOfClass:[NSString class]] && FXShowsExtension(item, filename)) self.primaryLabel.text = FXFullDisplayName(filename);
}

%end

#pragma mark - Live refresh

static void FXCollectViews(UIView *view, NSMutableArray *out) {
    if ([view isKindOfClass:[UICollectionView class]] && [NSStringFromClass(view.class) hasSuffix:@"DOCItemCollectionView"]) [out addObject:view];
    for (UIView *sub in view.subviews) FXCollectViews(sub, out);
}

// Redraw the file lists that are on screen so a change in Settings shows up without reopening Files.
static void FXReloadVisibleLists(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return;
    NSMutableArray *views = [NSMutableArray array];
    for (UIWindow *w in app.windows) FXCollectViews(w, views);
    for (UICollectionView *cv in views) [cv reloadData];
}

%ctor {
    gLock = [NSObject new];
    FXLoadPrefs();
    // Settings posts this after every change. The lists on screen are redrawn right away; if Files was
    // in the background, it is checked again when it comes back.
    int token;
    notify_register_dispatch(kFXNotification, &token, dispatch_get_main_queue(), ^(int t) {
        FXLoadPrefs();
        FXReloadVisibleLists();
        // In case the file was written after the notification (older settings pane, cfprefsd).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (FXLoadPrefs()) FXReloadVisibleLists();
        });
    });
    for (NSString *name in @[UIApplicationDidBecomeActiveNotification, @"NSExtensionHostDidBecomeActiveNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            if (FXLoadPrefs()) FXReloadVisibleLists();
        }];
    }
    %init;
}
