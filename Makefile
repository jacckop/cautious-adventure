ARCHS = arm64
TARGET = iphone:clang:latest:16.0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PiPVideoCall

PiPVideoCall_FILES = Tweak.mm
PiPVideoCall_FRAMEWORKS = UIKit AVFoundation AVKit QuartzCore
PiPVideoCall_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
PiPVideoCall_CCFLAGS = -std=c++17
PiPVideoCall_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
