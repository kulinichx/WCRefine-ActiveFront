ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WCRefineActiveFront
WCRefineActiveFront_FILES = ActiveFront.m
WCRefineActiveFront_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra
WCRefineActiveFront_FRAMEWORKS = UIKit Foundation
WCRefineActiveFront_LDFLAGS = -Wl,-install_name,@rpath/WCRefineActiveFront.dylib

include $(THEOS_MAKE_PATH)/library.mk
