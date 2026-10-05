ARCHS := arm64  # arm64e
TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES := imgui
ENT_PLIST := $(PWD)/supports/entitlements.plist
LAUNCHD_PLIST := $(PWD)/layout/Library/LaunchDaemons/imgui.test.iospmt.hudservices.plist

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := imgui

imgui_USE_MODULES := 0

imgui_FILES += $(wildcard sources/*.mm sources/*.m)
imgui_FILES += $(wildcard sources/KIF/*.mm sources/KIF/*.m)
imgui_FILES += $(wildcard sources/imgui/*.cpp)
imgui_FILES += $(wildcard sources/imgui/backends/*.mm)

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
imgui_FILES += libroot/dyn.c
imgui_LIBRARIES += roothide
endif

# App Intents will be built from Xcode.
# imgui_FILES += $(wildcard sources/Intents/*.swift)

imgui_CFLAGS += -fobjc-arc
imgui_CFLAGS += -Iheaders
imgui_CFLAGS += -Isources
imgui_CFLAGS += -Isources/KIF
imgui_CFLAGS += -Isources/imgui
imgui_CFLAGS += -include supports/hudapp-prefix.pch
# ImGui wants C++14 or later. The ObjC-only parts of the prefix header are
# guarded by __OBJC__ so they are a no-op in the plain .cpp translation units.
imgui_CXXFLAGS += -std=c++14
MainApplication.mm_CCFLAGS += -std=c++14


imgui_LDFLAGS += -Flibraries

imgui_FRAMEWORKS += CoreGraphics CoreServices QuartzCore IOKit UIKit Metal MetalKit
imgui_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices SpringBoardServices
imgui_CODESIGN_FLAGS += -Ssupports/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk



before-all::
	$(ECHO_NOTHING)defaults write $(LAUNCHD_PLIST) ProgramArguments -array "$(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/imgui.app/imgui" "-hud" || true$(ECHO_END)
	$(ECHO_NOTHING)plutil -convert xml1 $(LAUNCHD_PLIST)$(ECHO_END)
	$(ECHO_NOTHING)chmod 0644 $(LAUNCHD_PLIST)$(ECHO_END)

after-package::
	$(ECHO_NOTHING)mkdir -p packages $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cp -rp $(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Applications/imgui.app $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)defaults delete $(THEOS_STAGING_DIR)/Payload/imgui.app/Info.plist CFBundleIconName || true$(ECHO_END)
	$(ECHO_NOTHING)defaults write $(THEOS_STAGING_DIR)/Payload/imgui.app/Info.plist CFBundleVersion -string $(shell openssl rand -hex 4)$(ECHO_END)
	$(ECHO_NOTHING)plutil -convert xml1 $(THEOS_STAGING_DIR)/Payload/imgui.app/Info.plist$(ECHO_END)
	$(ECHO_NOTHING)chmod 0644 $(THEOS_STAGING_DIR)/Payload/imgui.app/Info.plist$(ECHO_END)
	$(ECHO_NOTHING)cd $(THEOS_STAGING_DIR); zip -qr imgui.tipa Payload; cd -;$(ECHO_END)
	$(ECHO_NOTHING)mv $(THEOS_STAGING_DIR)/imgui.tipa packages/imgui.tipa$(ECHO_END)
