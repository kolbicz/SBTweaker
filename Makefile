# Rootless is the default. Override THEOS, TARGET and
# THEOS_PACKAGE_SCHEME=roothide for a roothide package.
export THEOS ?= $(HOME)/theos

export TARGET ?= iphone:clang:15.6:15.0
export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = SBTweaker
SBTweaker_FILES = Tweak.x
SBTweaker_CFLAGS = -fobjc-arc
# make SBT_TRACE=1 builds a test package that logs every wake/sleep step as
# [SBT:WAKE]. Release builds leave it off.
SBT_TRACE ?= 0
SBTweaker_CFLAGS += -DSBT_WAKE_TRACE=$(SBT_TRACE)

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBTweaker_LIBRARIES += roothide
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += sbtweakerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
