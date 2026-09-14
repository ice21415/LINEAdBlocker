#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL LABClassNameIsAd(NSString *name) {
    if (name.length == 0) return NO;

    // LINE's own ad SDK and its concrete ad surfaces.
    NSArray<NSString *> *exactOrPrefix = @[
        @"LAD",
        @"LineAdvertise",
        @"AdHome",
        @"AdTimeline",
        @"AdWallet",
        @"AdBigBanner",
        @"AdGCSHome",
        @"GoogleBannerAdView",
        @"GoogleNativeAdView",
        @"RightAlignedGoogleNativeAdView",
        @"AdvertiseServiceProxy",
        @"FloatingBannerServiceProxy"
    ];
    for (NSString *part in exactOrPrefix) {
        if ([name hasPrefix:part] || [name containsString:part]) return YES;
    }

    // Google Mobile Ads / IMA display surfaces. Keep this limited to ad
    // objects, rather than blocking every class containing "Banner".
    NSArray<NSString *> *googleAdTypes = @[
        @"GADBannerView",
        @"GAMBannerView",
        @"GADNativeAdView",
        @"GADMediaView",
        @"GADTemplateView",
        @"GADInterstitial",
        @"GADRewarded",
        @"IMAAdDisplayContainer",
        @"IMAAVPlayerVideoDisplay"
    ];
    for (NSString *part in googleAdTypes) {
        if ([name hasPrefix:part] || [name containsString:part]) return YES;
    }
    return NO;
}

static BOOL LABIsAdObject(id object) {
    if (!object) return NO;

    // Walk the complete class hierarchy. Ad SDKs frequently expose a
    // private subclass whose name does not contain GAD/LAD.
    for (Class cls = [object class]; cls; cls = class_getSuperclass(cls)) {
        NSString *name = NSStringFromClass(cls);
        if (LABClassNameIsAd(name)) return YES;

        NSBundle *bundle = [NSBundle bundleForClass:cls];
        NSString *bundlePath = bundle.bundlePath.lowercaseString;
        if ([bundlePath containsString:@"lineadvertisesdk"] ||
            [bundlePath containsString:@"googleinteractiveima"] ||
            [bundlePath containsString:@"googlemobileads"] ||
            [bundlePath containsString:@"lineadsdk"]) {
            return YES;
        }
    }
    return NO;
}

static void (*LAB_orig_addSubview)(UIView *, SEL, UIView *);
static void LAB_addSubview(UIView *self, SEL _cmd, UIView *view) {
    if (LABIsAdObject(view)) return;
    LAB_orig_addSubview(self, _cmd, view);
}

static void (*LAB_orig_didMoveToWindow)(UIView *, SEL);
static void LAB_didMoveToWindow(UIView *self, SEL _cmd) {
    LAB_orig_didMoveToWindow(self, _cmd);
    if (LABIsAdObject(self)) {
        self.hidden = YES;
        [self removeFromSuperview];
    }
}

static void (*LAB_orig_present)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void));
static void LAB_present(UIViewController *self, SEL _cmd, UIViewController *vc,
                        BOOL animated, void (^completion)(void)) {
    if (LABIsAdObject(vc)) {
        if (completion) completion();
        return;
    }
    LAB_orig_present(self, _cmd, vc, animated, completion);
}

__attribute__((constructor))
static void LINEAdBlockerInit(void) {
    Class viewClass = objc_getClass("UIView");
    Class controllerClass = objc_getClass("UIViewController");
    if (viewClass) {
        Method addSubview = class_getInstanceMethod(viewClass, @selector(addSubview:));
        Method didMoveToWindow = class_getInstanceMethod(viewClass, @selector(didMoveToWindow));
        if (addSubview) {
            LAB_orig_addSubview = (void (*)(UIView *, SEL, UIView *))
                method_setImplementation(addSubview, (IMP)LAB_addSubview);
        }
        if (didMoveToWindow) {
            LAB_orig_didMoveToWindow = (void (*)(UIView *, SEL))
                method_setImplementation(didMoveToWindow, (IMP)LAB_didMoveToWindow);
        }
    }
    if (controllerClass) {
        Method present = class_getInstanceMethod(
            controllerClass, @selector(presentViewController:animated:completion:));
        if (present) {
            LAB_orig_present = (void (*)(UIViewController *, SEL, UIViewController *, BOOL, void (^)(void)))
                method_setImplementation(present, (IMP)LAB_present);
        }
    }
}
