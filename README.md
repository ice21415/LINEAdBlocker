# LINEAdBlocker

This bundle is LINE `jp.naver.line`, version `26.1.1` (`2026.204.1746`).

## Findings

- First-party advertising is in `LineAdvertiseSDK2.framework` and
  `LineAdSDK_LADKit.bundle`.
- The main executable references LINE ad surfaces such as
  `AdHomeBigBannerView`, `AdTimelineAuthorView`, `AdWalletBigBannerCarouselView`,
  `LineChatTabUIAdvertiseServiceProxy`, and
  `LineChatTabUIFloatingBannerServiceProxy`.
- Google ad delivery is also linked through `GoogleInteractiveMediaAds.framework`
  and exposes GAD banner/native/interstitial/rewarded classes.

## Build

Copy this directory to a Theos environment, then run:

```sh
make package FINALPACKAGE=1
```

Install the generated `.deb` on the test device and respring. This source is
deliberately scoped to the LINE bundle and only filters identified ad classes.

## Validation still required

The supplied Windows workspace contains an extracted app bundle, not a running
iOS device or a Theos toolchain. Runtime verification is therefore still
required for Home, Timeline/VOOM, chat-tab floating ads, wallet, and any ad
opened from a web view. If a new LINE release renames its ad view, add that
class to `LABClassNameIsAd` after observing it on-device.
