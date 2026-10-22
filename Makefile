TARGET = iphone:clang:16.5:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = TikTok

TWEAK_NAME = GTokGlass
GTokGlass_FILES = Tweak.m
GTokGlass_CFLAGS = -fobjc-arc -O2 -Wall -Wno-unused-function
GTokGlass_FRAMEWORKS = Foundation UIKit
GTokGlass_LDFLAGS = -install_name @executable_path/Frameworks/GTokGlass.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
