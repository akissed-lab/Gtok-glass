//
//  GTokGlass - Liquid Glass unlocker for TikTok (iOS 26/27)
//  Works on top of the GTok mod. No jailbreak required.
//
//  What it does:
//   * TikTok 46.x already ships TikTok's own Liquid Glass design system
//     (TUXLiquidGlass*), but every component is gated behind an experiment
//     getter on _TtC12TUXSwiftBase14TUXExperiments (returns BOOL).
//     We flip those getters to YES, so TikTok renders its native glass:
//     buttons, dialogs, sheets, menus, popovers, modals, toasts, notices.
//   * Optionally forces a few AB flags (feed cards / tab bar fix).
//   * Optional own UIGlassEffect background for the custom TTKTabBar
//     (TikTok's tab bar is not part of the TUX glass system).
//
//  Config + log: Documents/GTokGlass/ (visible in Files app > On My iPhone > TikTok)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - config / log

static NSString *const kGGDirName = @"GTokGlass";
static BOOL gLogEnabled = YES;
static NSLock *gLogLock = nil;
static NSString *gLogPath = nil;

static NSString *GGDocuments(void) {
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

static NSString *GGDir(void) {
    return [GGDocuments() stringByAppendingPathComponent:kGGDirName];
}

static void GGLogv(NSString *fmt, va_list ap) {
    if (!gLogEnabled) return;
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    NSLog(@"[GTokGlass] %@", line);
    if (!gLogPath) return;
    @synchronized (gLogLock) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[([line stringByAppendingString:@"\n"]) dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    }
}

static void GGLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt); GGLogv(fmt, ap); va_end(ap);
}

#pragma mark - runtime helpers

static Class GGClassWithSuffix(NSString *suffix) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * count);
    if (!classes) return Nil;
    objc_getClassList(classes, count);
    Class found = Nil;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name isEqualToString:suffix] || [name hasSuffix:suffix]) {
            found = classes[i];
            if ([name isEqualToString:suffix]) break;
        }
    }
    free(classes);
    return found;
}

static BOOL GGHookClassMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static BOOL GGHookInstanceMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static BOOL GGTypeIsBool(const char *types) {
    if (!types || !types[0]) return NO;
    return types[0] == 'B' || types[0] == 'c';
}

#pragma mark - forced BOOL getters

static BOOL GGYES(id self, SEL _cmd) { return YES; }
static BOOL GGNO(id self, SEL _cmd) { return NO; }

static id GGOBJYES(id self, SEL _cmd) {
    static NSNumber *n;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ n = @YES; });
    return n;
}

#pragma mark - experiment flags (TUX design system)

static int GGForceTUXExperiments(void) {
    Class cls = GGClassWithSuffix(@"TUXExperiments");
    if (!cls) {
        GGLog(@"TUXExperiments: class NOT found");
        return 0;
    }
    GGLog(@"TUXExperiments: %s", class_getName(cls));

    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    int hooked = 0, total = 0;
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(methods[i]));
        if ([sel rangeOfString:@"LiquidGlass"].location == NSNotFound) continue;
        total++;
        const char *types = method_getTypeEncoding(methods[i]);
        if (types && types[0] && !GGTypeIsBool(types)) {
            GGLog(@"  skip  %@ (%s)", sel, types);
            continue;
        }
        method_setImplementation(methods[i], (IMP)GGYES);
        hooked++;
        GGLog(@"  on    %@ (%s)", sel, types ?: "?");
    }
    free(methods);
    GGLog(@"TUXExperiments: %d/%d glass flags forced", hooked, total);
    return hooked;
}

#pragma mark - AB flags (feed cards / tab bar fix)

// Only names that are clearly boolean. AB getters return NSNumber *, so @YES.
static const char *kABGlassSelectors[] = {
    "ttTabbarLiquidGlassFix",
    "ugFeedCardLiquidGlassEnable",
    "feedStandardButtonEnableLiquidGlass",
    "enableBigCardLiquidGlass",
    "ecPdpStoreV2EnableLiquidGlass",
    "innerPushLiquidGlassEnable",
    "innerPushLiquidGlassInteractiveEnable",
    NULL
};

static int GGForceABFlags(void) {
    Class cls = GGClassWithSuffix(@"ABTestCodeGen");
    if (!cls) {
        GGLog(@"ABTestCodeGen: class NOT found");
        return 0;
    }
    int hooked = 0;
    for (int i = 0; kABGlassSelectors[i]; i++) {
        SEL sel = sel_registerName(kABGlassSelectors[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) {
            GGLog(@"  missing %s", kABGlassSelectors[i]);
            continue;
        }
        method_setImplementation(m, (IMP)GGOBJYES);
        hooked++;
        GGLog(@"  on      %s", kABGlassSelectors[i]);
    }
    GGLog(@"ABTestCodeGen: %d AB flags forced", hooked);
    return hooked;
}

#pragma mark - optional: own Liquid Glass on the custom tab bar

static BOOL gTabBarGlass = NO;
static Class gTTKTabBarClass = Nil;

static UIVisualEffect *GGGlassEffect(void) {
    // UIGlassEffect exists since iOS 26. Fall back to ultra thin material.
    Class glass = NSClassFromString(@"UIGlassEffect");
    if (glass) {
        UIVisualEffect *effect = [[glass alloc] init];
        if (effect) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

static void GGApplyTabBarGlass(UIView *bar) {
    if (!bar || !gTabBarGlass) return;
    const char *kName = "ggGlassBackground";
    UIView *existing = objc_getAssociatedObject(bar, kName);
    UIVisualEffectView *glass = nil;
    if ([existing isKindOfClass:[UIVisualEffectView class]]) {
        glass = (UIVisualEffectView *)existing;
    } else {
        glass = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = YES;
        objc_setAssociatedObject(bar, kName, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = bar.bounds;
    if (!glass.superview) {
        [bar insertSubview:glass atIndex:0];
    }
    glass.layer.cornerRadius = bar.layer.cornerRadius;
    glass.clipsToBounds = YES;

    // hide the original solid background
    for (NSString *key in @[@"bgView", @"backgroundView"]) {
        @try {
            UIView *v = [bar valueForKey:key];
            if ([v isKindOfClass:[UIView class]]) v.hidden = YES;
        } @catch (__unused NSException *e) {}
    }
}

static void (*gOrigTabBarLayout)(id, SEL);

static void GGReplacementTabBarLayout(id self, SEL _cmd) {
    if (gOrigTabBarLayout) gOrigTabBarLayout(self, _cmd);
    @try {
        GGApplyTabBarGlass((UIView *)self);
    } @catch (__unused NSException *e) {}
}

static void GGSetupTabBarGlass(void) {
    if (!gTabBarGlass) return;
    gTTKTabBarClass = GGClassWithSuffix(@"TTKTabBar");
    if (!gTTKTabBarClass) {
        GGLog(@"TTKTabBar: class NOT found, own tab bar glass skipped");
        return;
    }
    SEL sel = sel_registerName("layoutSubviews");
    Method m = class_getInstanceMethod(gTTKTabBarClass, sel);
    if (m) {
        gOrigTabBarLayout = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)GGReplacementTabBarLayout);
        GGLog(@"TTKTabBar: own glass background enabled");
    }
}

#pragma mark - status capsule (visible proof that the tweak is alive)

static void GGShowStatus(NSString *text) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
        if (!window) return;

        UIVisualEffectView *capsule = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        capsule.translatesAutoresizingMaskIntoConstraints = NO;
        capsule.layer.cornerRadius = 18;
        capsule.clipsToBounds = YES;

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = text;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        label.textColor = [UIColor labelColor];
        [capsule.contentView addSubview:label];

        [window addSubview:capsule];
        [NSLayoutConstraint activateConstraints:@[
            [capsule.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [capsule.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:10],
            [label.leadingAnchor constraintEqualToAnchor:capsule.contentView.leadingAnchor constant:14],
            [label.trailingAnchor constraintEqualToAnchor:capsule.contentView.trailingAnchor constant:-14],
            [label.topAnchor constraintEqualToAnchor:capsule.contentView.topAnchor constant:7],
            [label.bottomAnchor constraintEqualToAnchor:capsule.contentView.bottomAnchor constant:-7],
        ]];
        capsule.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{ capsule.alpha = 1; } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.4 delay:3.5 options:0 animations:^{ capsule.alpha = 0; } completion:^(BOOL finished2) {
                [capsule removeFromSuperview];
            }];
        }];
    });
}

#pragma mark - bootstrap

static NSDictionary *GGLoadConfig(void) {
    NSMutableDictionary *def = [@{@"enabled": @YES,
                                  @"nativeGlass": @YES,
                                  @"abGlass": @YES,
                                  @"tabBarGlass": @NO,
                                  @"log": @YES,
                                  @"showStatus": @YES} mutableCopy];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:GGDir() withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [GGDir() stringByAppendingPathComponent:@"config.json"];
    if (![fm fileExistsAtPath:path]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:def options:NSJSONWritingPrettyPrinted error:NULL];
        [d writeToFile:path atomically:YES];
    } else {
        NSData *d = [NSData dataWithContentsOfFile:path];
        if (d) {
            id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) [def addEntriesFromDictionary:obj];
        }
    }
    return def;
}

static void GGBootstrap(void) {
    NSDictionary *cfg = GGLoadConfig();

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:GGDir() withIntermediateDirectories:YES attributes:nil error:NULL];
    gLogPath = [GGDir() stringByAppendingPathComponent:@"log.txt"];
    [[NSData data] writeToFile:gLogPath atomically:YES];  // truncate
    [fm createFileAtPath:gLogPath contents:nil attributes:nil];
    gLogLock = [NSLock new];
    gLogEnabled = [cfg[@"log"] boolValue];

    if (![cfg[@"enabled"] boolValue]) {
        GGLog(@"disabled via config, doing nothing");
        return;
    }

    UIDevice *dev = [UIDevice currentDevice];
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    GGLog(@"GTokGlass 0.1 | iOS %@ | %@ | TikTok %@ (%@)",
          dev.systemVersion, dev.model,
          info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]);

    if ([cfg[@"nativeGlass"] boolValue]) {
        GGForceTUXExperiments();
    }
    if ([cfg[@"abGlass"] boolValue]) {
        GGForceABFlags();
    }

    gTabBarGlass = [cfg[@"tabBarGlass"] boolValue];
    GGSetupTabBarGlass();

    int ok = (NSClassFromString(@"_TtC12TUXSwiftBase14TUXExperiments") != Nil);
    if ([cfg[@"showStatus"] boolValue]) {
        GGShowStatus(ok ? @"Liquid Glass: ON" : @"Liquid Glass: class not found");
    }
    GGLog(@"done");
}

__attribute__((constructor))
static void GTokGlassInit(void) {
    @autoreleasepool {
        GGBootstrap();
    }
}
