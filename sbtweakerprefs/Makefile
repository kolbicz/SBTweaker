include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SBTweakerPrefs
SBTweakerPrefs_FILES = SBTRootListController.m SBTNumberCell.m SBTExcludedAppsController.m
SBTweakerPrefs_FRAMEWORKS = UIKit
SBTweakerPrefs_PRIVATE_FRAMEWORKS = Preferences
SBTweakerPrefs_INSTALL_PATH = /Library/PreferenceBundles
# Shown in the pane; read from the package's control file so it can't drift.
SBT_VERSION := $(shell sed -n 's/^Version: *//p' ../control)
SBTweakerPrefs_CFLAGS = -fobjc-arc -DSBT_VERSION='"$(SBT_VERSION)"'

include $(THEOS_MAKE_PATH)/bundle.mk
