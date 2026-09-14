#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL LABClassNameIsAd(NSString *name) {
    if (name.length == 0) return NO;

    // LINE's own ad SDK and its concrete ad surfaces.
    NSArray<NSString *> *exactOrPrefix = @[
        @"LAD",
        @"LineAdvertise",
        @"LineAdFeatureSupport",
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

static char LABCollapsedKey;
static char LABZeroHeightKey;

// Hiding a view removes its pixels, but Auto Layout still reserves the view's
// old height.  Collapse only constraints that directly reference the ad view,
// then leave the view in the hierarchy so LINE's layout engine stays stable.
static void LABCollapseAdView(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &LABCollapsedKey)) return;
    objc_setAssociatedObject(view, &LABCollapsedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    [view invalidateIntrinsicContentSize];
    [view.superview setNeedsLayout];

    // Keep LINE's original constraints intact, but add a low-conflict
    // zero-height constraint so fixed ad slots can collapse naturally.
    if (!objc_getAssociatedObject(view, &LABZeroHeightKey) &&
        !view.translatesAutoresizingMaskIntoConstraints) {
        NSLayoutConstraint *zeroHeight =
            [NSLayoutConstraint constraintWithItem:view
                                         attribute:NSLayoutAttributeHeight
                                         relatedBy:NSLayoutRelationEqual
                                            toItem:nil
                                         attribute:NSLayoutAttributeNotAnAttribute
                                        multiplier:1.0
                                          constant:0.0];
        zeroHeight.priority = 999.0;
        [view addConstraint:zeroHeight];
        objc_setAssociatedObject(view, &LABZeroHeightKey, zeroHeight,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void LABCollapseAdContainerChain(UIView *adView) {
    UIView *candidate = adView;
    UIView *parent = candidate.superview;
    NSUInteger depth = 0;

    // The visible gap is often owned by a wrapper view around the actual ad.
    // Hide only wrappers whose visible children are all ad views (or the
    // candidate we just collapsed). Stop as soon as normal UI is present.
    while (parent && depth < 2 &&
           ![parent isKindOfClass:[UIWindow class]] && parent.superview) {
        NSUInteger visibleCount = 0;
        BOOL containsOnlyAdContent = YES;
        for (UIView *child in parent.subviews) {
            if (child.hidden || child.alpha <= 0.01) continue;
            visibleCount++;
            if (child != candidate && !LABIsAdObject(child)) {
                containsOnlyAdContent = NO;
                break;
            }
        }
        if (!containsOnlyAdContent || visibleCount > 1) break;

        LABCollapseAdView(parent);
        candidate = parent;
        parent = candidate.superview;
        depth++;
    }
}

static void LABHideAdAndCollapse(UIView *view) {
    LABCollapseAdView(view);
    LABCollapseAdContainerChain(view);
}

static void (*LAB_orig_addSubview)(UIView *, SEL, UIView *);
static void LAB_addSubview(UIView *self, SEL _cmd, UIView *view) {
    LAB_orig_addSubview(self, _cmd, view);
    if (LABIsAdObject(view)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LABHideAdAndCollapse(view);
        });
    }
}

static void (*LAB_orig_didMoveToWindow)(UIView *, SEL);
static void LAB_didMoveToWindow(UIView *self, SEL _cmd) {
    LAB_orig_didMoveToWindow(self, _cmd);
    if (LABIsAdObject(self)) {
        LABHideAdAndCollapse(self);
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

static void LABRemoveAdViews(UIView *view) {
    for (UIView *child in [view.subviews copy]) {
        if (LABIsAdObject(child)) {
            LABHideAdAndCollapse(child);
        } else {
            LABRemoveAdViews(child);
        }
    }
}

static void LABSweepWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            LABRemoveAdViews(window);
        }
    }
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

    // Some LineAdFeatureSupport views are created and attached before the
    // first addSubview hook is reached. Sweep only known ad SDK/module views
    // on the main thread so those already-present surfaces are removed too.
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         repeats:YES
                                           block:^(__unused NSTimer *timer) {
            LABSweepWindows();
        }];
    });
}
