ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LINEAdBlocker
LINEAdBlocker_FILES = Tweak.xm
LINEAdBlocker_CFLAGS = -fobjc-arc
LINEAdBlocker_FRAMEWORKS = UIKit
LINEAdBlocker_PRIVATE_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
