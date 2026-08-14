TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = WaffleStore
ARCHS = arm64
PACKAGE_VERSION = $(THEOS_PACKAGE_BASE_VERSION)
PACKAGE_FORMAT = ipa

GO_EASY_ON_ME = 1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = WaffleStore

WaffleStore_FILES = $(wildcard *.m)
WaffleStore_FRAMEWORKS = UIKit CoreGraphics CoreServices SystemConfiguration Security
WaffleStore_PRIVATE_FRAMEWORKS = Preferences StoreKitUI AppStoreDaemon StoreServices
WaffleStore_CFLAGS = -fobjc-arc
WaffleStore_LDFLAGS = -lsqlite3 -lz
WaffleStore_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
