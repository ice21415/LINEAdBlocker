#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

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
static BOOL LABDidPresentDebugReport = NO;
static const BOOL LABEnableDiagnostics = NO;
static BOOL LABDidPresentNetworkReport = NO;
static char LABFixedHeightCollapsedKey;
static __weak UICollectionView *LABWalletCollectionView;
static NSIndexPath *LABWalletAdIndexPath;
static CGFloat LABWalletAdHeight = 0.0;

static NSString *LABDebugChainForView(UIView *view) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    UIView *current = view;
    for (NSUInteger depth = 0; current && depth < 7; depth++, current = current.superview) {
        CGRect frame = current.frame;
        [lines addObject:[NSString stringWithFormat:@"%lu. %@  %.0f×%.0f",
                          (unsigned long)depth, NSStringFromClass(current.class),
                          frame.size.width, frame.size.height]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *LABDebugLayoutDetailsForView(UIView *view) {
    NSMutableArray<NSString *> *details = [NSMutableArray array];
    UIView *current = view;
    UICollectionViewCell *cell = nil;
    UICollectionView *collectionView = nil;
    for (NSUInteger depth = 0; current && depth < 7; depth++, current = current.superview) {
        if (!cell && [current isKindOfClass:[UICollectionViewCell class]]) {
            cell = (UICollectionViewCell *)current;
        }
        if (!collectionView && [current isKindOfClass:[UICollectionView class]]) {
            collectionView = (UICollectionView *)current;
        }
    }
    if (cell && collectionView) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        [details addObject:[NSString stringWithFormat:@"cell index: %@\nlayout: %@",
                            indexPath ?: @"(not visible)",
                            NSStringFromClass(collectionView.collectionViewLayout.class)]];
    }

    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight ||
            constraint.secondAttribute == NSLayoutAttributeHeight) {
            [details addObject:[NSString stringWithFormat:@"self H: %.0f p%.0f",
                                constraint.constant, constraint.priority]];
        }
    }
    for (NSLayoutConstraint *constraint in view.superview.constraints) {
        if ((constraint.firstItem == view || constraint.secondItem == view) &&
            (constraint.firstAttribute == NSLayoutAttributeHeight ||
             constraint.secondAttribute == NSLayoutAttributeHeight)) {
            [details addObject:[NSString stringWithFormat:@"parent H: %.0f p%.0f",
                                constraint.constant, constraint.priority]];
        }
    }
    return details.count ? [details componentsJoinedByString:@"\n"] : @"no direct height constraint";
}

static void LABPresentDebugReport(UIView *view) {
    if (!LABEnableDiagnostics || LABDidPresentDebugReport || !view.window) return;
    NSString *className = NSStringFromClass(view.class);
    // Home's container has already been identified and handled. Keep the
    // one-shot diagnostic available for the remaining Chat/Wallet surfaces.
    if ([className containsString:@"LADHome"] || [className containsString:@"AdHome"]) return;
    LABDidPresentDebugReport = YES;
    NSString *report = [NSString stringWithFormat:@"%@\n\n%@",
                        LABDebugChainForView(view), LABDebugLayoutDetailsForView(view)];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = view.window.rootViewController;
        while (controller.presentedViewController) {
            controller = controller.presentedViewController;
        }
        if (!controller) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"LINEAdBlocker 診斷"
                             message:report
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"確定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static BOOL LABIsPotentialAdRequest(NSURL *URL) {
    NSString *value = [NSString stringWithFormat:@"%@%@", URL.host.lowercaseString,
                       URL.path.lowercaseString];
    return [value containsString:@"advert"] || [value containsString:@"smartch"] ||
           [value containsString:@"linead"] || [value containsString:@"/ads/"] ||
           [value containsString:@"/ad/"];
}

static void LABPresentNetworkReport(NSURL *URL) {
    if (LABDidPresentNetworkReport || !URL) return;
    LABDidPresentNetworkReport = YES;
    NSString *endpoint = [NSString stringWithFormat:@"%@%@", URL.host ?: @"", URL.path ?: @""];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                window = ((UIWindowScene *)scene).windows.firstObject;
                if (window) break;
            }
        }
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) controller = controller.presentedViewController;
        if (!controller) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"LINEAdBlocker 網路診斷"
                             message:endpoint
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"確定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
}

static NSURLSessionDataTask *(*LAB_orig_dataTaskWithRequest)(NSURLSession *, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
static NSURLSessionDataTask *LAB_dataTaskWithRequest(NSURLSession *self, SEL _cmd,
                                                      NSURLRequest *request,
                                                      void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    if (LABIsPotentialAdRequest(request.URL)) LABPresentNetworkReport(request.URL);
    return LAB_orig_dataTaskWithRequest(self, _cmd, request, completion);
}

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

}

static void LABZeroFixedHeightConstraints(UIView *view) {
    if (!view || objc_getAssociatedObject(view, &LABFixedHeightCollapsedKey)) return;
    objc_setAssociatedObject(view, &LABFixedHeightCollapsedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray<NSArray<NSLayoutConstraint *> *> *groups = @[
        view.constraints ?: @[], view.superview.constraints ?: @[]
    ];
    for (NSArray<NSLayoutConstraint *> *constraints in groups) {
        for (NSLayoutConstraint *constraint in constraints) {
            BOOL touchesView = constraint.firstItem == view || constraint.secondItem == view;
            BOOL isHeight = constraint.firstAttribute == NSLayoutAttributeHeight ||
                            constraint.secondAttribute == NSLayoutAttributeHeight;
            if (touchesView && isHeight && constraint.constant != 0.0) {
                constraint.constant = 0.0;
            }
        }
    }
    [view.superview setNeedsLayout];
}

static void LABRecordWalletAdCell(UIView *view) {
    UIView *current = view;
    UICollectionViewCell *cell = nil;
    UICollectionView *collectionView = nil;
    for (NSUInteger depth = 0; current && depth < 7; depth++, current = current.superview) {
        if (!cell && [NSStringFromClass(current.class) containsString:@"WalletAdvertiseCell"]) {
            cell = (UICollectionViewCell *)current;
        }
        if (!collectionView && [current isKindOfClass:[UICollectionView class]]) {
            collectionView = (UICollectionView *)current;
        }
    }
    if (cell && collectionView) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (indexPath) {
            LABWalletCollectionView = collectionView;
            LABWalletAdIndexPath = [indexPath copy];
            LABWalletAdHeight = CGRectGetHeight(cell.frame);
            [collectionView.collectionViewLayout invalidateLayout];
        }
    }
}

static void LABCollapseKnownAdHost(UIView *adView) {
    for (UIView *current = adView; current; current = current.superview) {
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"TopBannerBoxView"]) {
            LABZeroFixedHeightConstraints(current);
            break;
        }
        if ([name containsString:@"WalletAdvertiseCell"]) {
            LABRecordWalletAdCell(adView);
            break;
        }
        if ([current isKindOfClass:[UIWindow class]]) break;
    }
}

static BOOL LABContainsAdDescendant(UIView *view) {
    for (UIView *child in view.subviews) {
        if (LABIsAdObject(child) || LABContainsAdDescendant(child)) return YES;
    }
    return NO;
}

static BOOL LABShouldUseZeroSize(UIView *view) {
    if (LABIsAdObject(view)) return YES;

    if ([NSStringFromClass(view.class) containsString:@"TopBannerBoxView"] &&
        LABContainsAdDescendant(view)) {
        return YES;
    }

    // LINE reserves its banner area as a self-sizing table/collection cell.
    // Collapse that cell only when its subtree contains a known ad view.
    if ([view isKindOfClass:[UITableViewCell class]] ||
        [view isKindOfClass:[UICollectionReusableView class]]) {
        return LABContainsAdDescendant(view);
    }
    return NO;
}

static Class LABClassNamedLike(NSString *fragment) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    Class result = Nil;
    for (int i = 0; i < count; i++) {
        if ([NSStringFromClass(classes[i]) containsString:fragment]) {
            result = classes[i];
            break;
        }
    }
    free(classes);
    return result;
}

// Home banners are hosted by a custom collection cell which overrides UIKit's
// normal fitting path. Hook that concrete cell so its 344-point placeholder is
// never returned to the home collection layout once it contains an ad.
static UICollectionViewLayoutAttributes *(*LAB_orig_homeCellPreferredSize)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *);
static UICollectionViewLayoutAttributes *LAB_homeCellPreferredSize(
    UICollectionViewCell *self, SEL _cmd, UICollectionViewLayoutAttributes *attributes) {
    if (LABContainsAdDescendant(self)) {
        UICollectionViewLayoutAttributes *collapsed = [attributes copy];
        collapsed.size = CGSizeMake(attributes.size.width, 0.0);
        return collapsed;
    }
    return LAB_orig_homeCellPreferredSize(self, _cmd, attributes);
}

static CGSize (*LAB_orig_homeCellSystemFittingSize)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority);
static CGSize LAB_homeCellSystemFittingSize(UIView *self, SEL _cmd, CGSize size,
                                            UILayoutPriority horizontal,
                                            UILayoutPriority vertical) {
    return LABContainsAdDescendant(self) ? CGSizeZero :
        LAB_orig_homeCellSystemFittingSize(self, _cmd, size, horizontal, vertical);
}

static void LABInstallHomeBannerCellHooks(void) {
    Class cellClass = LABClassNamedLike(@"GCSHomeTabCommonCell");
    if (!cellClass) return;

    SEL preferredSelector = @selector(preferredLayoutAttributesFittingAttributes:);
    Method preferredMethod = class_getInstanceMethod(cellClass, preferredSelector);
    if (preferredMethod) {
        LAB_orig_homeCellPreferredSize =
            (UICollectionViewLayoutAttributes *(*)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *))
            method_getImplementation(preferredMethod);
        if (!class_addMethod(cellClass, preferredSelector, (IMP)LAB_homeCellPreferredSize,
                             method_getTypeEncoding(preferredMethod))) {
            LAB_orig_homeCellPreferredSize =
                (UICollectionViewLayoutAttributes *(*)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *))
                method_setImplementation(preferredMethod, (IMP)LAB_homeCellPreferredSize);
        }
    }

    SEL fittingSelector =
        @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    Method fittingMethod = class_getInstanceMethod(cellClass, fittingSelector);
    if (fittingMethod) {
        LAB_orig_homeCellSystemFittingSize =
            (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
            method_getImplementation(fittingMethod);
        if (!class_addMethod(cellClass, fittingSelector, (IMP)LAB_homeCellSystemFittingSize,
                             method_getTypeEncoding(fittingMethod))) {
            LAB_orig_homeCellSystemFittingSize =
                (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
                method_setImplementation(fittingMethod, (IMP)LAB_homeCellSystemFittingSize);
        }
    }
}

// Wallet uses a separate self-sizing collection cell for its banner.
static UICollectionViewLayoutAttributes *(*LAB_orig_walletCellPreferredSize)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *);
static UICollectionViewLayoutAttributes *LAB_walletCellPreferredSize(
    UICollectionViewCell *self, SEL _cmd, UICollectionViewLayoutAttributes *attributes) {
    if (LABContainsAdDescendant(self)) {
        UICollectionViewLayoutAttributes *collapsed = [attributes copy];
        collapsed.size = CGSizeMake(attributes.size.width, 0.0);
        return collapsed;
    }
    return LAB_orig_walletCellPreferredSize(self, _cmd, attributes);
}

static CGSize (*LAB_orig_walletCellSystemFittingSize)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority);
static CGSize LAB_walletCellSystemFittingSize(UIView *self, SEL _cmd, CGSize size,
                                              UILayoutPriority horizontal,
                                              UILayoutPriority vertical) {
    return LABContainsAdDescendant(self) ? CGSizeZero :
        LAB_orig_walletCellSystemFittingSize(self, _cmd, size, horizontal, vertical);
}

static void LABInstallWalletBannerCellHooks(void) {
    Class cellClass = LABClassNamedLike(@"WalletAdvertiseCell");
    if (!cellClass) return;

    SEL preferredSelector = @selector(preferredLayoutAttributesFittingAttributes:);
    Method preferredMethod = class_getInstanceMethod(cellClass, preferredSelector);
    if (preferredMethod) {
        LAB_orig_walletCellPreferredSize =
            (UICollectionViewLayoutAttributes *(*)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *))
            method_getImplementation(preferredMethod);
        if (!class_addMethod(cellClass, preferredSelector, (IMP)LAB_walletCellPreferredSize,
                             method_getTypeEncoding(preferredMethod))) {
            LAB_orig_walletCellPreferredSize =
                (UICollectionViewLayoutAttributes *(*)(UICollectionViewCell *, SEL, UICollectionViewLayoutAttributes *))
                method_setImplementation(preferredMethod, (IMP)LAB_walletCellPreferredSize);
        }
    }

    SEL fittingSelector =
        @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    Method fittingMethod = class_getInstanceMethod(cellClass, fittingSelector);
    if (fittingMethod) {
        LAB_orig_walletCellSystemFittingSize =
            (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
            method_getImplementation(fittingMethod);
        if (!class_addMethod(cellClass, fittingSelector, (IMP)LAB_walletCellSystemFittingSize,
                             method_getTypeEncoding(fittingMethod))) {
            LAB_orig_walletCellSystemFittingSize =
                (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
                method_setImplementation(fittingMethod, (IMP)LAB_walletCellSystemFittingSize);
        }
    }
}

// Chat's banner lives in a standalone container rather than a cell.
static CGSize (*LAB_orig_topBannerIntrinsicSize)(UIView *, SEL);
static CGSize LAB_topBannerIntrinsicSize(UIView *self, SEL _cmd) {
    return LABContainsAdDescendant(self) ? CGSizeZero :
        LAB_orig_topBannerIntrinsicSize(self, _cmd);
}

static CGSize (*LAB_orig_topBannerSizeThatFits)(UIView *, SEL, CGSize);
static CGSize LAB_topBannerSizeThatFits(UIView *self, SEL _cmd, CGSize size) {
    return LABContainsAdDescendant(self) ? CGSizeZero :
        LAB_orig_topBannerSizeThatFits(self, _cmd, size);
}

static CGSize (*LAB_orig_topBannerSystemFittingSize)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority);
static CGSize LAB_topBannerSystemFittingSize(UIView *self, SEL _cmd, CGSize size,
                                             UILayoutPriority horizontal,
                                             UILayoutPriority vertical) {
    return LABContainsAdDescendant(self) ? CGSizeZero :
        LAB_orig_topBannerSystemFittingSize(self, _cmd, size, horizontal, vertical);
}

static void LABInstallChatTopBannerHooks(void) {
    Class bannerClass = LABClassNamedLike(@"TopBannerBoxView");
    if (!bannerClass) return;

    SEL intrinsicSelector = @selector(intrinsicContentSize);
    Method intrinsicMethod = class_getInstanceMethod(bannerClass, intrinsicSelector);
    if (intrinsicMethod) {
        LAB_orig_topBannerIntrinsicSize = (CGSize (*)(UIView *, SEL))
            method_getImplementation(intrinsicMethod);
        if (!class_addMethod(bannerClass, intrinsicSelector, (IMP)LAB_topBannerIntrinsicSize,
                             method_getTypeEncoding(intrinsicMethod))) {
            LAB_orig_topBannerIntrinsicSize = (CGSize (*)(UIView *, SEL))
                method_setImplementation(intrinsicMethod, (IMP)LAB_topBannerIntrinsicSize);
        }
    }

    SEL sizeSelector = @selector(sizeThatFits:);
    Method sizeMethod = class_getInstanceMethod(bannerClass, sizeSelector);
    if (sizeMethod) {
        LAB_orig_topBannerSizeThatFits = (CGSize (*)(UIView *, SEL, CGSize))
            method_getImplementation(sizeMethod);
        if (!class_addMethod(bannerClass, sizeSelector, (IMP)LAB_topBannerSizeThatFits,
                             method_getTypeEncoding(sizeMethod))) {
            LAB_orig_topBannerSizeThatFits = (CGSize (*)(UIView *, SEL, CGSize))
                method_setImplementation(sizeMethod, (IMP)LAB_topBannerSizeThatFits);
        }
    }

    SEL fittingSelector =
        @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    Method fittingMethod = class_getInstanceMethod(bannerClass, fittingSelector);
    if (fittingMethod) {
        LAB_orig_topBannerSystemFittingSize =
            (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
            method_getImplementation(fittingMethod);
        if (!class_addMethod(bannerClass, fittingSelector, (IMP)LAB_topBannerSystemFittingSize,
                             method_getTypeEncoding(fittingMethod))) {
            LAB_orig_topBannerSystemFittingSize =
                (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
                method_setImplementation(fittingMethod, (IMP)LAB_topBannerSystemFittingSize);
        }
    }
}

static BOOL LABIsTrackedWalletLayout(UICollectionViewLayout *layout) {
    return layout.collectionView && layout.collectionView == LABWalletCollectionView &&
        LABWalletAdIndexPath && LABWalletAdHeight > 0.0;
}

static UICollectionViewLayoutAttributes *LABAdjustedWalletAttributes(
    UICollectionViewLayoutAttributes *attributes) {
    if (!attributes || !LABWalletAdIndexPath) return attributes;
    UICollectionViewLayoutAttributes *adjusted = [attributes copy];
    NSIndexPath *indexPath = adjusted.indexPath;
    if (adjusted.representedElementCategory == UICollectionElementCategoryCell &&
        indexPath.section == LABWalletAdIndexPath.section) {
        CGRect frame = adjusted.frame;
        if (indexPath.item == LABWalletAdIndexPath.item) {
            frame.size.height = 0.0;
        } else if (indexPath.item > LABWalletAdIndexPath.item) {
            frame.origin.y -= LABWalletAdHeight;
        }
        adjusted.frame = frame;
    }
    return adjusted;
}

static NSArray<UICollectionViewLayoutAttributes *> *(*LAB_orig_walletLayoutAttributesInRect)(UICollectionViewLayout *, SEL, CGRect);
static NSArray<UICollectionViewLayoutAttributes *> *LAB_walletLayoutAttributesInRect(
    UICollectionViewLayout *self, SEL _cmd, CGRect rect) {
    NSArray<UICollectionViewLayoutAttributes *> *attributes =
        LAB_orig_walletLayoutAttributesInRect(self, _cmd, rect);
    if (!LABIsTrackedWalletLayout(self)) return attributes;
    NSMutableArray<UICollectionViewLayoutAttributes *> *adjusted =
        [NSMutableArray arrayWithCapacity:attributes.count];
    for (UICollectionViewLayoutAttributes *attribute in attributes) {
        [adjusted addObject:LABAdjustedWalletAttributes(attribute)];
    }
    return adjusted;
}

static UICollectionViewLayoutAttributes *(*LAB_orig_walletLayoutAttributesForItem)(UICollectionViewLayout *, SEL, NSIndexPath *);
static UICollectionViewLayoutAttributes *LAB_walletLayoutAttributesForItem(
    UICollectionViewLayout *self, SEL _cmd, NSIndexPath *indexPath) {
    UICollectionViewLayoutAttributes *attributes =
        LAB_orig_walletLayoutAttributesForItem(self, _cmd, indexPath);
    return LABIsTrackedWalletLayout(self) ? LABAdjustedWalletAttributes(attributes) : attributes;
}

static CGSize (*LAB_orig_walletCollectionContentSize)(UICollectionViewLayout *, SEL);
static CGSize LAB_walletCollectionContentSize(UICollectionViewLayout *self, SEL _cmd) {
    CGSize size = LAB_orig_walletCollectionContentSize(self, _cmd);
    if (LABIsTrackedWalletLayout(self)) {
        size.height = MAX(0.0, size.height - LABWalletAdHeight);
    }
    return size;
}

static void LABInstallWalletFlowLayoutHooks(void) {
    Class layoutClass = LABClassNamedLike(@"WalletCollectionViewFlowLayout");
    if (!layoutClass) return;

    SEL elementsSelector = @selector(layoutAttributesForElementsInRect:);
    Method elementsMethod = class_getInstanceMethod(layoutClass, elementsSelector);
    if (elementsMethod) {
        LAB_orig_walletLayoutAttributesInRect =
            (NSArray<UICollectionViewLayoutAttributes *> *(*)(UICollectionViewLayout *, SEL, CGRect))
            method_getImplementation(elementsMethod);
        if (!class_addMethod(layoutClass, elementsSelector, (IMP)LAB_walletLayoutAttributesInRect,
                             method_getTypeEncoding(elementsMethod))) {
            LAB_orig_walletLayoutAttributesInRect =
                (NSArray<UICollectionViewLayoutAttributes *> *(*)(UICollectionViewLayout *, SEL, CGRect))
                method_setImplementation(elementsMethod, (IMP)LAB_walletLayoutAttributesInRect);
        }
    }

    SEL itemSelector = @selector(layoutAttributesForItemAtIndexPath:);
    Method itemMethod = class_getInstanceMethod(layoutClass, itemSelector);
    if (itemMethod) {
        LAB_orig_walletLayoutAttributesForItem =
            (UICollectionViewLayoutAttributes *(*)(UICollectionViewLayout *, SEL, NSIndexPath *))
            method_getImplementation(itemMethod);
        if (!class_addMethod(layoutClass, itemSelector, (IMP)LAB_walletLayoutAttributesForItem,
                             method_getTypeEncoding(itemMethod))) {
            LAB_orig_walletLayoutAttributesForItem =
                (UICollectionViewLayoutAttributes *(*)(UICollectionViewLayout *, SEL, NSIndexPath *))
                method_setImplementation(itemMethod, (IMP)LAB_walletLayoutAttributesForItem);
        }
    }

    SEL contentSizeSelector = @selector(collectionViewContentSize);
    Method contentSizeMethod = class_getInstanceMethod(layoutClass, contentSizeSelector);
    if (contentSizeMethod) {
        LAB_orig_walletCollectionContentSize = (CGSize (*)(UICollectionViewLayout *, SEL))
            method_getImplementation(contentSizeMethod);
        if (!class_addMethod(layoutClass, contentSizeSelector, (IMP)LAB_walletCollectionContentSize,
                             method_getTypeEncoding(contentSizeMethod))) {
            LAB_orig_walletCollectionContentSize = (CGSize (*)(UICollectionViewLayout *, SEL))
                method_setImplementation(contentSizeMethod, (IMP)LAB_walletCollectionContentSize);
        }
    }
}

// LINE sizes several ad slots before the view is attached to a window.  By
// returning zero during that sizing phase, the collection/table layout does
// not reserve an otherwise-empty banner row.
static CGSize (*LAB_orig_intrinsicContentSize)(UIView *, SEL);
static CGSize LAB_intrinsicContentSize(UIView *self, SEL _cmd) {
    return LABShouldUseZeroSize(self) ? CGSizeZero : LAB_orig_intrinsicContentSize(self, _cmd);
}

static CGSize (*LAB_orig_sizeThatFits)(UIView *, SEL, CGSize);
static CGSize LAB_sizeThatFits(UIView *self, SEL _cmd, CGSize size) {
    return LABShouldUseZeroSize(self) ? CGSizeZero : LAB_orig_sizeThatFits(self, _cmd, size);
}

static CGSize (*LAB_orig_systemLayoutSizeFittingSize)(UIView *, SEL, CGSize);
static CGSize LAB_systemLayoutSizeFittingSize(UIView *self, SEL _cmd, CGSize size) {
    return LABShouldUseZeroSize(self) ? CGSizeZero :
        LAB_orig_systemLayoutSizeFittingSize(self, _cmd, size);
}

static CGSize (*LAB_orig_systemLayoutSizeFittingSizeWithPriority)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority);
static CGSize LAB_systemLayoutSizeFittingSizeWithPriority(UIView *self, SEL _cmd, CGSize size,
                                                           UILayoutPriority horizontal,
                                                           UILayoutPriority vertical) {
    return LABShouldUseZeroSize(self) ? CGSizeZero :
        LAB_orig_systemLayoutSizeFittingSizeWithPriority(self, _cmd, size, horizontal, vertical);
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
    LABCollapseKnownAdHost(view);
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
            LABPresentDebugReport(child);
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
    Class sessionClass = objc_getClass("NSURLSession");
    if (viewClass) {
        Method addSubview = class_getInstanceMethod(viewClass, @selector(addSubview:));
        Method didMoveToWindow = class_getInstanceMethod(viewClass, @selector(didMoveToWindow));
        Method intrinsicContentSize = class_getInstanceMethod(viewClass, @selector(intrinsicContentSize));
        Method sizeThatFits = class_getInstanceMethod(viewClass, @selector(sizeThatFits:));
        Method systemLayoutSizeFittingSize =
            class_getInstanceMethod(viewClass, @selector(systemLayoutSizeFittingSize:));
        Method systemLayoutSizeFittingSizeWithPriority = class_getInstanceMethod(
            viewClass,
            @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:));
        if (addSubview) {
            LAB_orig_addSubview = (void (*)(UIView *, SEL, UIView *))
                method_setImplementation(addSubview, (IMP)LAB_addSubview);
        }
        if (didMoveToWindow) {
            LAB_orig_didMoveToWindow = (void (*)(UIView *, SEL))
                method_setImplementation(didMoveToWindow, (IMP)LAB_didMoveToWindow);
        }
        if (intrinsicContentSize) {
            LAB_orig_intrinsicContentSize = (CGSize (*)(UIView *, SEL))
                method_setImplementation(intrinsicContentSize, (IMP)LAB_intrinsicContentSize);
        }
        if (sizeThatFits) {
            LAB_orig_sizeThatFits = (CGSize (*)(UIView *, SEL, CGSize))
                method_setImplementation(sizeThatFits, (IMP)LAB_sizeThatFits);
        }
        if (systemLayoutSizeFittingSize) {
            LAB_orig_systemLayoutSizeFittingSize = (CGSize (*)(UIView *, SEL, CGSize))
                method_setImplementation(systemLayoutSizeFittingSize,
                                         (IMP)LAB_systemLayoutSizeFittingSize);
        }
        if (systemLayoutSizeFittingSizeWithPriority) {
            LAB_orig_systemLayoutSizeFittingSizeWithPriority =
                (CGSize (*)(UIView *, SEL, CGSize, UILayoutPriority, UILayoutPriority))
                method_setImplementation(systemLayoutSizeFittingSizeWithPriority,
                                         (IMP)LAB_systemLayoutSizeFittingSizeWithPriority);
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
    if (sessionClass) {
        Method dataTaskWithRequest = class_getInstanceMethod(
            sessionClass, @selector(dataTaskWithRequest:completionHandler:));
        if (dataTaskWithRequest) {
            LAB_orig_dataTaskWithRequest =
                (NSURLSessionDataTask *(*)(NSURLSession *, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)))
                method_setImplementation(dataTaskWithRequest, (IMP)LAB_dataTaskWithRequest);
        }
    }

    LABInstallHomeBannerCellHooks();
    LABInstallWalletBannerCellHooks();
    LABInstallChatTopBannerHooks();
    LABInstallWalletFlowLayoutHooks();

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
