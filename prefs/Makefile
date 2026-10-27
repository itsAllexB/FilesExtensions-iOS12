# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:14.5:12.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = FilesExtensionsPrefs
FilesExtensionsPrefs_FILES = FXRootListController.m
FilesExtensionsPrefs_FRAMEWORKS = UIKit
FilesExtensionsPrefs_PRIVATE_FRAMEWORKS = Preferences
FilesExtensionsPrefs_INSTALL_PATH = /Library/PreferenceBundles
FilesExtensionsPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
