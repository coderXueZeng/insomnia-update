ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Insomnia
Insomnia_FILES = Tweak.x InsConfig.m InsLLM.m InsHistory.m InsMemory.m InsMCP.m InsGen.m InsSend.m InsMedia.m InsUpdate.m InsSticker.m InsProgress.m InsOutbox.m InsAutoLink.m InsStat.m InsHot.m InsRelay.m InsVoice.m
Insomnia_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-arc-performSelector-leaks
Insomnia_FRAMEWORKS = Foundation UIKit Photos AVFoundation VideoToolbox CoreMedia CoreVideo
Insomnia_LDFLAGS = -lsqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
