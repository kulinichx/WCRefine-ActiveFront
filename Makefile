ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZZWCRefineActiveFront
ZZWCRefineActiveFront_FILES = Tweak.xm
ZZWCRefineActiveFront_CFLAGS = -fobjc-arc
ZZWCRefineActiveFront_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
