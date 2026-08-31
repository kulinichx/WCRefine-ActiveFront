ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WCRefineGroup
WCRefineGroup_FILES = ActiveFront.m
WCRefineGroup_CFLAGS = -fobjc-arc -fblocks -Wall -Wextra
WCRefineGroup_FRAMEWORKS = UIKit Foundation
WCRefineGroup_LDFLAGS = -Wl,-install_name,@rpath/WCRefineGroup.dylib

include $(THEOS_MAKE_PATH)/library.mk
