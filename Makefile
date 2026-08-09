# Build against the roothide theos fork (installed side-by-side).
export THEOS ?= $(HOME)/theos-roothide

export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME ?= roothide

INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = SBTweaker
SBTweaker_FILES = Tweak.x
SBTweaker_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += sbtweakerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
