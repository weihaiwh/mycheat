export ARCHS = arm64e
export TARGET = iphone:clang:15.0:15.0
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WHWB

WHWB_FILES = Tweak.mm
WHWB_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
WHWB_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
