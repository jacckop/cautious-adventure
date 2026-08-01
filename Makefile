ARCHS = arm64
TARGET = iphone:clang:latest:16.0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = PiPSubtitles

PiPSubtitles_FILES = Tweak.mm
PiPSubtitles_FRAMEWORKS = UIKit AVFoundation AVKit CoreMedia CoreVideo CoreImage QuartzCore
PiPSubtitles_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
PiPSubtitles_CCFLAGS = -std=c++17
PiPSubtitles_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk
