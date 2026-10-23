//
//  GTokGlass - Liquid Glass unlocker for TikTok (iOS 26/27)
//  Works on top of the GTok mod. No jailbreak required.
//
//  v0.2 changes:
//   * forces the GLOBAL capability gate +[TUXAppInfoUtils supportLiquidGlass]
//     (v0.1 only forced per-component TUXExperiments getters, which is not
//      enough: every glass path checks the capability gate first)
//   * hooks the master config key tux_liquid_glass_enabled / block list
//   * logs the ORIGINAL value of every hooked getter, plus call counters,
//     so we can see which gate is really blocking
//   * logs the TUXLiquidGlass* class inventory
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <pthread.h>

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

#pragma mark - hook registry (keeps original IMP + call counter)

#define GG_MAX_ENTRIES 64

typedef struct {
    SEL sel;
    IMP orig;
    int calls;
    BOOL isClassMethod;
} GGEntry;

static GGEntry gEnt[GG_MAX_ENTRIES];
static int gEntCount = 0;
static pthread_mutex_t gEntLock = PTHREAD_MUTEX_INITIALIZER;

static GGEntry *GGEntryFor(SEL sel) {
    GGEntry *found = NULL;
    pthread_mutex_lock(&gEntLock);
    for (int i = 0; i < gEntCount; i++) {
        if (gEnt[i].sel == sel) { found = &gEnt[i]; break; }
    }
    pthread_mutex_unlock(&gEntLock);
    return found;
}

static void GGAddEntry(SEL sel, IMP orig, BOOL isClassMethod) {
    pthread_mutex_lock(&gEntLock);
    if (gEntCount < GG_MAX_ENTRIES) {
        gEnt[gEntCount].sel = sel;
        gEnt[gEntCount].orig = orig;
        gEnt[gEntCount].calls = 0;
        gEnt[gEntCount].isClassMethod = isClassMethod;
        gEntCount++;
    }
    pthread_mutex_unlock(&gEntLock);
}

static int GGNoteCall(GGEntry *e) {
    int n = 0;
    pthread_mutex_lock(&gEntLock);
    if (e) { n = e->calls; e->calls++; }
    pthread_mutex_unlock(&gEntLock);
    return n;
}

#pragma mark - hook bodies

static BOOL GGHookYES(id self, SEL _cmd) {
    GGEntry *e = GGEntryFor(_cmd);
    BOOL orig = NO;
    if (e && e->orig) orig = ((BOOL (*)(id, SEL))e->orig)(self, _cmd);
    int n = GGNoteCall(e);
    if (n < 3) GGLog(@"[hit] %@ orig=%d -> YES", NSStringFromSelector(_cmd), (int)orig);
    return YES;
}

static id GGHookObjYES(id self, SEL _cmd) {
    GGEntry *e = GGEntryFor(_cmd);
    id orig = nil;
    if (e && e->orig) orig = ((id (*)(id, SEL))e->orig)(self, _cmd);
    int n = GGNoteCall(e);
    if (n < 3) GGLog(@"[hit] %@ orig=%@ -> @YES", NSStringFromSelector(_cmd), orig);
    return @YES;
}

static id GGHookEmptyArray(id self, SEL _cmd) {
    GGEntry *e = GGEntryFor(_cmd);
    id orig = nil;
    if (e && e->orig) orig = ((id (*)(id, SEL))e->orig)(self, _cmd);
    int n = GGNoteCall(e);
    if (n < 3) GGLog(@"[hit] %@ orig=%@ -> @[]", NSStringFromSelector(_cmd), orig);
    static NSArray *empty; static dispatch_once_t once;
    dispatch_once(&once, ^{ empty = @[]; });
    return empty;
}

static id GGHookLogOnly(id self, SEL _cmd) {
    GGEntry *e = GGEntryFor(_cmd);
    id v = nil;
    if (e && e->orig) v = ((id (*)(id, SEL))e->orig)(self, _cmd);
    int n = GGNoteCall(e);
    if (n < 3) GGLog(@"[hit] %@ = %@", NSStringFromSelector(_cmd), v);
    return v;
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
        if ([name isEqualToString:suffix]) { found = classes[i]; break; }
        if (!found && [name hasSuffix:suffix]) found = classes[i];
    }
    free(classes);
    return found;
}

static BOOL GGTypeIsBool(const char *types) {
    if (!types || !types[0]) return NO;
    return types[0] == 'B' || types[0] == 'c';
}

// Hook `sel` on every loaded class (instance methods). Returns number of classes hooked.
static int GGHookSelectorEverywhere(NSString *selName, IMP hook) {
    SEL sel = sel_registerName(selName.UTF8String);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return 0;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * count);
    if (!classes) return 0;
    objc_getClassList(classes, count);
    int hooked = 0;
    for (int i = 0; i < count; i++) {
        Method m = class_getInstanceMethod(classes[i], sel);
        if (!m) continue;
        IMP cur = method_getImplementation(m);
        if (cur == hook) continue;
        GGAddEntry(sel, cur, NO);
        method_setImplementation(m, hook);
        hooked++;
    }
    free(classes);
    return hooked;
}

static void GGHookInstance(Class cls, NSString *selName, IMP hook) {
    if (!cls) return;
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    GGAddEntry(sel, method_getImplementation(m), NO);
    method_setImplementation(m, hook);
}

static void GGHookClass(Class cls, NSString *selName, IMP hook) {
    if (!cls) return;
    SEL sel = sel_registerName(selName.UTF8String);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    GGAddEntry(sel, method_getImplementation(m), YES);
    method_setImplementation(m, hook);
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
        if (!GGTypeIsBool(types)) {
            GGLog(@"  skip  %@ (%s)", sel, types ?: "?");
            continue;
        }
        SEL s = method_getName(methods[i]);
        GGAddEntry(s, method_getImplementation(methods[i]), NO);
        method_setImplementation(methods[i], (IMP)GGHookYES);
        hooked++;
        GGLog(@"  on    %@ (%s)", sel, types ?: "?");
    }
    free(methods);
    GGLog(@"TUXExperiments: %d/%d glass flags forced", hooked, total);
    return hooked;
}

#pragma mark - global capability gate

// +[TUXAppInfoUtils supportLiquidGlass] -- every glass path checks this first.
static BOOL GGForceCapabilityGate(void) {
    Class cls = GGClassWithSuffix(@"TUXAppInfoUtils");
    if (!cls) {
        GGLog(@"TUXAppInfoUtils: class NOT found");
        return NO;
    }
    SEL sel = sel_registerName("supportLiquidGlass");
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        GGLog(@"TUXAppInfoUtils: +supportLiquidGlass NOT found");
        return NO;
    }
    const char *types = method_getTypeEncoding(m);
    GGLog(@"TUXAppInfoUtils: +supportLiquidGlass types=%s", types ?: "?");
    if (!GGTypeIsBool(types)) {
        GGLog(@"capability gate: unexpected return type, not hooking");
        return NO;
    }
    IMP orig = method_getImplementation(m);
    BOOL before = ((BOOL (*)(id, SEL))orig)((id)cls, sel);
    GGAddEntry(sel, orig, YES);
    method_setImplementation(m, (IMP)GGHookYES);
    GGLog(@"capability gate: orig=%d -> forced YES", (int)before);
    return before;
}

#pragma mark - master config keys

static const char *kABGlassSelectors[] = {
    "ttTabbarLiquidGlassFix",
    "ugFeedCardLiquidGlassEnable",
    "feedStandardButtonEnableLiquidGlass",
    "enableBigCardLiquidGlass",
    "ecPdpStoreV2EnableLiquidGlass",
    "innerPushLiquidGlassEnable",
    "innerPushLiquidGlassInteractiveEnable",
    "tux_liquid_glass_enabled",
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
        GGAddEntry(sel, method_getImplementation(m), NO);
        method_setImplementation(m, (IMP)GGHookObjYES);
        hooked++;
        GGLog(@"  on      %s", kABGlassSelectors[i]);
    }

    // device block list: empty array so the device is never excluded
    SEL blSel = sel_registerName("tux_liquid_glass_device_model_block_list");
    Method blm = class_getInstanceMethod(cls, blSel);
    if (blm) {
        GGAddEntry(blSel, method_getImplementation(blm), NO);
        method_setImplementation(blm, (IMP)GGHookEmptyArray);
        hooked++;
        GGLog(@"  on      tux_liquid_glass_device_model_block_list -> @[]");
    }
    // component versions: read-only logging (return type unknown)
    SEL cvSel = sel_registerName("tux_liquid_glass_component_versions");
    Method cvm = class_getInstanceMethod(cls, cvSel);
    if (cvm) {
        GGAddEntry(cvSel, method_getImplementation(cvm), NO);
        method_setImplementation(cvm, (IMP)GGHookLogOnly);
        GGLog(@"  log     tux_liquid_glass_component_versions");
    }
    GGLog(@"ABTestCodeGen: %d AB flags forced", hooked);
    return hooked;
}

// Hook the config center so we can see what the app asks for and override the
// master switch / block list when they are still off.
static id (*gOrigConfigGet)(id, SEL, id, Class, id) = NULL;

static id GGConfigGet(id self, SEL _cmd, id key, Class objectClass, id defaultValue) {
    id v = gOrigConfigGet ? gOrigConfigGet(self, _cmd, key, objectClass, defaultValue) : defaultValue;
    NSString *ks = [key isKindOfClass:[NSString class]] ? key : [key description];
    if (ks && [ks rangeOfString:@"liquid_glass" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        int n = GGNoteCall(GGEntryFor(_cmd));
        if (n < 6) GGLog(@"[cfg] %@ = %@ (class=%@ def=%@)", ks, v, objectClass, defaultValue);
        BOOL isMaster = [ks isEqualToString:@"tux_liquid_glass_enabled"];
        BOOL isBlock = [ks isEqualToString:@"tux_liquid_glass_device_model_block_list"];
        if (isMaster || isBlock) {
            id forced = nil;
            if ([defaultValue isKindOfClass:[NSNumber class]]) forced = isMaster ? @YES : @0;
            else if ([defaultValue isKindOfClass:[NSString class]]) forced = isMaster ? @"1" : @"";
            else if ([defaultValue isKindOfClass:[NSArray class]]) forced = @[];
            else if (isMaster) forced = @YES;
            if (forced) {
                if (n < 6) GGLog(@"[cfg]   -> forced %@", forced);
                return forced;
            }
        }
    }
    return v;
}

static void GGHookConfigCenter(void) {
    Class cls = GGClassWithSuffix(@"TUXConfigCenter");
    if (!cls) { GGLog(@"TUXConfigCenter: class NOT found"); return; }
    SEL sel = sel_registerName("getObjectForKey:objectClass:defaultValue:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { GGLog(@"TUXConfigCenter: getter NOT found"); return; }
    gOrigConfigGet = (id (*)(id, SEL, id, Class, id))method_getImplementation(m);
    GGAddEntry(sel, method_getImplementation(m), NO);
    method_setImplementation(m, (IMP)GGConfigGet);
    GGLog(@"TUXConfigCenter: config getter hooked");
}

#pragma mark - TUXLiquidGlass inventory

static void GGDumpGlassClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    objc_getClassList(classes, count);
    int found = 0;
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name rangeOfString:@"LiquidGlass"].location == NSNotFound) continue;
        found++;
        unsigned int n = 0;
        Method *ms = class_copyMethodList(classes[i], &n);
        NSMutableArray *sel = [NSMutableArray array];
        for (unsigned int j = 0; j < n && j < 12; j++) {
            [sel addObject:NSStringFromSelector(method_getName(ms[j]))];
        }
        free(ms);
        GGLog(@"  class %@ [%u] %@", name, n, [sel componentsJoinedByString:@","]);
    }
    free(classes);
    GGLog(@"LiquidGlass classes: %d", found);
}

#pragma mark - button setup probe

static void (*gOrigUpdateSetup)(id, SEL) = NULL;

static void GGUpdateSetup(id self, SEL _cmd) {
    if (gOrigUpdateSetup) gOrigUpdateSetup(self, _cmd);
    static int n = 0;
    if (n < 10) {
        n++;
        BOOL on = NO;
        @try {
            on = ((BOOL (*)(id, SEL))objc_msgSend)(self, sel_registerName("isLiquidGlassEnabled"));
        } @catch (__unused NSException *e) {}
        GGLog(@"[button] %@ glass=%d", NSStringFromClass([self class]), (int)on);
    }
}

static void GGHookButtonSetup(void) {
    Class cls = GGClassWithSuffix(@"TUXButton");
    if (!cls) { GGLog(@"TUXButton: class NOT found"); return; }
    SEL sel = sel_registerName("_updateLiquidGlassSetup");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { GGLog(@"TUXButton: _updateLiquidGlassSetup NOT found"); return; }
    gOrigUpdateSetup = (void (*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)GGUpdateSetup);
    GGLog(@"TUXButton: setup probe installed");
}

#pragma mark - optional: own Liquid Glass on the custom tab bar

static BOOL gTabBarGlass = NO;
static BOOL gTabBarCapsule = NO;
static UIView *(*gOrigTabBarLayout)(id, SEL) = NULL;

// hides every stock background layer of the tab bar
static void GGSetBarBackgroundHidden(UIView *bar) {
    for (NSString *key in @[@"bgView", @"backgroundView", @"separatorLine"]) {
        @try {
            UIView *v = [bar valueForKey:key];
            if ([v isKindOfClass:[UIView class]]) v.hidden = YES;
        } @catch (__unused NSException *e) {}
    }
}

static UIVisualEffect *GGGlassEffect(void) {
    // UIGlassEffect exists since iOS 26. -init alone yields an empty effect on
    // some builds, so prefer +effectWithStyle: when available.
    Class glass = NSClassFromString(@"UIGlassEffect");
    if (glass) {
        SEL s = NSSelectorFromString(@"effectWithStyle:");
        if ([glass respondsToSelector:s]) {
            id (*fn)(id, SEL, NSInteger) = (void *)objc_msgSend;
            UIVisualEffect *effect = fn((id)glass, s, 0);
            if (effect) return effect;
        }
        UIVisualEffect *effect = [[glass alloc] init];
        if (effect) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

static void GGApplyTabBarGlass(UIView *bar) {
    if (!bar) return;
    static const void *kKey = &kKey;
    UIVisualEffectView *glass = objc_getAssociatedObject(bar, kKey);
    if (![glass isKindOfClass:[UIVisualEffectView class]]) {
        glass = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        glass.userInteractionEnabled = NO;
        objc_setAssociatedObject(bar, kKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.frame = bar.bounds;
    if (!glass.superview) [bar insertSubview:glass atIndex:0];
    GGSetBarBackgroundHidden(bar);
}

#pragma mark - floating capsule tab bar

// Theme-aware tint: light -> milky, dark -> smoky. Updates automatically when
// the user switches appearance because it is a dynamic UIColor.
static UIColor *GGCapsuleTintColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.06];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.22];
    }];
}

static const void *kGGCapBarKey = &kGGCapBarKey;
static const void *kGGCapLensKey = &kGGCapLensKey;
static const void *kGGCapWatchedKey = &kGGCapWatchedKey;

// Moves the "liquid droplet" to the tapped item with a spring and leaves a
// short splash behind, mimicking the iOS 26 liquid lens.
@interface GGTabBarWatcher : NSObject
@end

@implementation GGTabBarWatcher

- (void)tabTapped:(UIControl *)sender {
    UIView *lens = objc_getAssociatedObject(sender, kGGCapLensKey);
    if (!lens || !lens.superview) return;

    UIView *host = lens.superview;
    CGRect target = [sender convertRect:sender.bounds toView:host];
    target = CGRectInset(target, 6.0, 4.0);
    if (target.size.width < 8.0 || target.size.height < 8.0) return;

    [UIView animateWithDuration:0.50
                          delay:0.0
         usingSpringWithDamping:0.62
          initialSpringVelocity:0.9
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        lens.frame = target;
        lens.transform = CGAffineTransformMakeScale(1.07, 1.07);
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            lens.transform = CGAffineTransformIdentity;
        }];
    }];

    UIView *splash = [[UIView alloc] initWithFrame:CGRectInset(target,
                                                               target.size.width * 0.30,
                                                               target.size.height * 0.30)];
    splash.userInteractionEnabled = NO;
    splash.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    splash.layer.cornerRadius = splash.bounds.size.height / 2.0;
    [host insertSubview:splash belowSubview:lens];
    [UIView animateWithDuration:0.55 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        splash.transform = CGAffineTransformMakeScale(2.0, 2.0);
        splash.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [splash removeFromSuperview];
    }];
}

@end

static GGTabBarWatcher *GGTabBarWatcherShared(void) {
    static GGTabBarWatcher *w = nil;
    if (!w) w = [GGTabBarWatcher new];
    return w;
}

static UIColor *GGDropletColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.16];
        }
        return [UIColor colorWithWhite:1.0 alpha:0.55];
    }];
}

static void GGApplyTabBarCapsule(UIView *bar) {
    static const void *kShadowKey = &kShadowKey;
    static const void *kCapsuleKey = &kCapsuleKey;

    GGSetBarBackgroundHidden(bar);
    bar.backgroundColor = [UIColor clearColor];

    // TikTok keeps a full-width blur band behind its own buttons; without this
    // the floating capsule looks like a bar glued to the screen edge.
    for (UIView *s in bar.subviews) {
        if ([NSStringFromClass([s class]) containsString:@"TTKTabBarBlurView"]) s.hidden = YES;
    }

    CGFloat safeBottom = bar.safeAreaInsets.bottom;
    CGRect b = bar.bounds;
    CGFloat contentH = b.size.height - safeBottom;
    if (contentH < 40.0) contentH = 40.0;

    // Match the iOS 26 floating tab bar platter: inset sides, taller than the
    // bare content area, sitting right above the home indicator.
    CGFloat insetX = b.size.width > 340.0 ? 21.0 : 12.0;
    CGFloat h = MAX(contentH, b.size.height - 21.0);
    CGRect capsuleRect = CGRectMake(insetX, 0.0, MAX(0.0, b.size.width - insetX * 2.0), h);

    UIView *shadow = objc_getAssociatedObject(bar, kShadowKey);
    if (![shadow isKindOfClass:[UIView class]]) {
        shadow = [[UIView alloc] init];
        shadow.userInteractionEnabled = NO;
        shadow.backgroundColor = [UIColor clearColor];
        shadow.layer.shadowColor = [UIColor blackColor].CGColor;
        shadow.layer.shadowOpacity = 0.22;
        shadow.layer.shadowRadius = 14.0;
        shadow.layer.shadowOffset = CGSizeMake(0, 5);
        objc_setAssociatedObject(bar, kShadowKey, shadow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIVisualEffectView *capsule = objc_getAssociatedObject(bar, kCapsuleKey);
    if (![capsule isKindOfClass:[UIVisualEffectView class]]) {
        capsule = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        capsule.userInteractionEnabled = NO;
        capsule.clipsToBounds = YES;
        capsule.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *tint = [[UIView alloc] init];
        tint.userInteractionEnabled = NO;
        tint.tag = 0x6766;
        tint.backgroundColor = GGCapsuleTintColor();
        [capsule.contentView addSubview:tint];
        objc_setAssociatedObject(bar, kCapsuleKey, capsule, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    shadow.frame = capsuleRect;
    capsule.frame = shadow.bounds;
    capsule.layer.cornerRadius = capsuleRect.size.height / 2.0;
    UIView *tint = [capsule.contentView viewWithTag:0x6766];
    tint.frame = capsule.contentView.bounds;

    if (shadow.superview != bar) [bar insertSubview:shadow atIndex:0];
    if (capsule.superview != shadow) [shadow addSubview:capsule];

    UIView *lens = objc_getAssociatedObject(bar, kGGCapLensKey);
    if (![lens isKindOfClass:[UIView class]]) {
        lens = [[UIView alloc] init];
        lens.userInteractionEnabled = NO;
        lens.backgroundColor = GGDropletColor();
        lens.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, kGGCapLensKey, lens, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (lens.superview != bar) [bar insertSubview:lens aboveSubview:shadow];

    // distribute the tab items inside the capsule so nothing sits outside it
    NSArray *buttons = nil;
    @try { buttons = [bar valueForKey:@"buttons"]; } @catch (__unused NSException *e) {}
    UIControl *selectedButton = nil;
    if ([buttons isKindOfClass:[NSArray class]] && buttons.count > 0) {
        CGFloat bw = capsuleRect.size.width / (CGFloat)buttons.count;
        CGFloat btnH = MIN(45.0, capsuleRect.size.height);
        CGFloat btnY = capsuleRect.origin.y + (capsuleRect.size.height - btnH) / 2.0;
        for (NSUInteger i = 0; i < buttons.count; i++) {
            id item = buttons[i];
            if (![item isKindOfClass:[UIView class]]) continue;
            UIView *btn = (UIView *)item;
            UIView *host = btn.superview ?: bar;
            CGRect slot = [bar convertRect:CGRectMake(capsuleRect.origin.x + bw * (CGFloat)i,
                                                      btnY,
                                                      bw,
                                                      btnH)
                                    toView:host];
            btn.frame = slot;
            if ([btn isKindOfClass:[UIControl class]] && ((UIControl *)btn).selected) {
                selectedButton = (UIControl *)btn;
            }
            if (!objc_getAssociatedObject(btn, kGGCapWatchedKey)) {
                objc_setAssociatedObject(btn, kGGCapWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(btn, kGGCapLensKey, lens, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if ([btn isKindOfClass:[UIControl class]]) {
                    [(UIControl *)btn addTarget:GGTabBarWatcherShared()
                                         action:@selector(tabTapped:)
                               forControlEvents:UIControlEventTouchUpInside];
                }
            }
        }
    }

    // place the droplet on the selected item unless it is currently animating
    if (lens.layer.animationKeys.count == 0) {
        UIControl *anchor = selectedButton;
        if (!anchor && [buttons isKindOfClass:[NSArray class]] && buttons.count > 0) {
            for (id item in buttons) {
                if ([item isKindOfClass:[UIControl class]] && ((UIControl *)item).selected) { anchor = item; break; }
            }
        }
        if (anchor) {
            CGRect target = [anchor convertRect:anchor.bounds toView:bar];
            target = CGRectInset(target, 6.0, 4.0);
            if (target.size.height < 8.0) {
                target = CGRectMake(target.origin.x,
                                    capsuleRect.origin.y + 4.0,
                                    target.size.width,
                                    capsuleRect.size.height - 8.0);
            }
            lens.frame = target;
        } else {
            CGFloat lw = capsuleRect.size.width / MAX(1.0, (CGFloat)buttons.count) - 12.0;
            lens.frame = CGRectMake(capsuleRect.origin.x + 6.0,
                                    capsuleRect.origin.y + 4.0,
                                    lw,
                                    capsuleRect.size.height - 8.0);
        }
    }
    lens.layer.cornerRadius = lens.frame.size.height / 2.0;
}

static void GGReplacementTabBarLayout(id self, SEL _cmd) {
    if (gOrigTabBarLayout) gOrigTabBarLayout(self, _cmd);
    @try {
        if (gTabBarCapsule) GGApplyTabBarCapsule((UIView *)self);
        else if (gTabBarGlass) GGApplyTabBarGlass((UIView *)self);
    } @catch (__unused NSException *e) {}
}

// When the capsule is on, the controller keeps pushing the stock background
// alpha/colour around while scrolling. Swallow those calls.
static void GGNoop(id self, SEL _cmd) { (void)self; (void)_cmd; }

static void GGSetupTabBarGlass(void) {
    if (!gTabBarGlass && !gTabBarCapsule) return;
    Class cls = GGClassWithSuffix(@"TTKTabBar");
    if (!cls) { GGLog(@"TTKTabBar: class NOT found"); return; }

    if (gTabBarCapsule) {
        for (NSString *name in @[@"updateBackgroundAlpha:",
                                 @"updateCompactTabBarBackgroundAlpha:",
                                 @"updateBackgroundColor:"]) {
            SEL s = sel_registerName(name.UTF8String);
            Method mm = class_getInstanceMethod(cls, s);
            if (mm) method_setImplementation(mm, (IMP)GGNoop);
        }
    }

    SEL sel = sel_registerName("layoutSubviews");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    gOrigTabBarLayout = (UIView *(*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)GGReplacementTabBarLayout);
    GGLog(@"TTKTabBar: %@ enabled", gTabBarCapsule ? @"capsule mode" : @"own glass background");
}

#pragma mark - universal glass skin (v0.4)

// A small rule table. Any view whose class name ends with `cls` gets decorated.
// Insets are asymmetric; negative values expand the glass beyond the view.
// radius < 0 means "pill" (height / 2); ring == YES draws a glass rim instead.
typedef struct {
    const char *cls;
    CGFloat left, top, right, bottom;
    CGFloat radius;
    BOOL clearBackground;
    BOOL ring;
} GGSkinRule;

static GGSkinRule gSkinRules[] = {
    // top feed tabs ("For You" / "Following" / ...). The labels actually span
    // 22..340 while the control is 48..342, so the plate must grow to the left.
    {"TikTokFeedTabControl",          -26.0,  0.0,  0.0, 0.0, -1.0, YES, NO},
    // messages: filter tab bar
    {"TTKInboxTabBarView",              8.0,  4.0,  8.0, 4.0, -1.0, YES, NO},
    // profile tabs (videos / reposts / likes)
    {"TTKProfileTabBarView",            8.0,  4.0,  8.0, 4.0, -1.0, YES, NO},
    // comment sheet tabs
    {"TTKCommentHeaderTabView",         8.0,  2.0,  8.0, 2.0, -1.0, YES, NO},
    // one chat row in the inbox
    {"AWEIMChatListCellContainerView",  0.0,  0.0,  0.0, 0.0, 18.0, NO,  NO},
    // search + LIVE buttons in the feed corner (40x40 containers, round icons inside)
    {"TTKFeedTabCornerItemView",        0.0,  0.0,  0.0, 0.0, -1.0, NO,  NO},
    // other search entry points
    {"TTKFeedDetailSearchButton",       0.0,  0.0,  0.0, 0.0, -1.0, NO,  NO},
    {"AWECommonSearchBar",              2.0,  2.0,  2.0, 2.0, -1.0, NO,  NO},
    {"AWESearchBar",                    2.0,  2.0,  2.0, 2.0, -1.0, NO,  NO},
    // glass rim around avatars (feed / profile / comments / inbox)
    {"AWEPlayInteractionAuthorView",    0.0,  0.0,  0.0, 0.0,  0.0, NO,  YES},
    {"TUXAvatar",                       0.0,  0.0,  0.0, 0.0,  0.0, NO,  YES},
};

static const void *kGGSkinGlassKey = &kGGSkinGlassKey;
static const void *kGGSkinRingKey = &kGGSkinRingKey;
static BOOL gGlassSkin = NO;

// Screens that must stay plain: Messages -> "pick a person" (new chat, create
// group, share a post, quick share) and the contact list. A view is skipped
// when it, or any of its ancestors, matches one of these class-name suffixes.
static NSArray<NSString *> *gSkinSkipScopes = nil;

static NSArray<NSString *> *GGDefaultSkinSkipScopes(void) {
    return @[@"UserPicker",       // TTKUserPicker* / UserPicker* (new chat, group, mention)
             @"ShareAvatar",      // AWEIMShareAvatar* (share sheet avatar grid)
             @"SharePostPicker",  // share a post -> people list
             @"ShareDMContacts",  // AWEIMMainPostShareDMContactsCell
             @"IMShareInput",     // IMShareInputCreateGroupView
             @"ContactList",      // AWEIMContactList* / AWEContactList*
             @"QuickShare"];      // AWEIMQuickSharePanel*
}

static BOOL GGNameInSkipScope(NSString *name) {
    if (name.length == 0) return NO;
    for (NSString *suffix in gSkinSkipScopes) {
        if ([suffix isKindOfClass:[NSString class]] && suffix.length > 0 &&
            [name hasSuffix:suffix]) {
            return YES;
        }
    }
    return NO;
}

static BOOL GGInSkippedScope(UIView *v) {
    if (gSkinSkipScopes.count == 0) return NO;
    NSInteger depth = 0;
    for (UIView *cur = v; cur && depth < 48; cur = cur.superview, depth++) {
        if (GGNameInSkipScope(NSStringFromClass([cur class]))) return YES;
    }
    return NO;
}

static void GGClearSkin(UIView *v) {
    id glass = objc_getAssociatedObject(v, kGGSkinGlassKey);
    if ([glass isKindOfClass:[UIView class]]) [(UIView *)glass removeFromSuperview];
    id ring = objc_getAssociatedObject(v, kGGSkinRingKey);
    if ([ring isKindOfClass:[UIView class]]) [(UIView *)ring removeFromSuperview];
    objc_setAssociatedObject(v, kGGSkinGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, kGGSkinRingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIColor *GGRingBorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.55];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.10];
    }];
}

static UIColor *GGRingShadowColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        if (tc.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:1.0 alpha:0.35];
        }
        return [UIColor colorWithWhite:0.0 alpha:0.12];
    }];
}

static const GGSkinRule *GGRuleForView(UIView *v) {
    NSString *name = NSStringFromClass([v class]);
    if (name.length == 0) return NULL;
    for (size_t i = 0; i < sizeof(gSkinRules) / sizeof(gSkinRules[0]); i++) {
        if ([name hasSuffix:[NSString stringWithUTF8String:gSkinRules[i].cls]]) {
            return &gSkinRules[i];
        }
    }
    return NULL;
}

static void GGApplySkinToView(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UIVisualEffectView class]]) return;
    CGRect b = v.bounds;
    if (b.size.width < 8.0 || b.size.height < 8.0) return;

    const GGSkinRule *rule = GGRuleForView(v);
    if (!rule) return;

    // reused cells can move between screens: drop the skin instead of keeping it
    if (GGInSkippedScope(v)) {
        GGClearSkin(v);
        return;
    }

    if (rule->clearBackground) v.backgroundColor = [UIColor clearColor];

    if (rule->ring) {
        UIView *ring = objc_getAssociatedObject(v, kGGSkinRingKey);
        if (![ring isKindOfClass:[UIView class]]) {
            ring = [[UIView alloc] init];
            ring.userInteractionEnabled = NO;
            ring.backgroundColor = [UIColor clearColor];
            ring.layer.cornerCurve = kCACornerCurveContinuous;
            ring.layer.borderWidth = 1.5;
            ring.layer.shadowOffset = CGSizeZero;
            ring.layer.shadowOpacity = 0.45;
            ring.layer.shadowRadius = 4.0;
            objc_setAssociatedObject(v, kGGSkinRingKey, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ring.frame = b;
        CGFloat d = MIN(b.size.width, b.size.height);
        ring.layer.cornerRadius = d / 2.0;
        ring.layer.borderColor = GGRingBorderColor().CGColor;
        ring.layer.shadowColor = GGRingShadowColor().CGColor;
        ring.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:ring.bounds].CGPath;
        if (ring.superview != v) [v addSubview:ring];
        return;
    }

    UIVisualEffectView *glass = objc_getAssociatedObject(v, kGGSkinGlassKey);
    if (![glass isKindOfClass:[UIVisualEffectView class]]) {
        glass = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *tint = [[UIView alloc] init];
        tint.userInteractionEnabled = NO;
        tint.tag = 0x6767;
        tint.backgroundColor = GGCapsuleTintColor();
        [glass.contentView addSubview:tint];
        objc_setAssociatedObject(v, kGGSkinGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIEdgeInsets ins = UIEdgeInsetsMake(rule->top, rule->left, rule->bottom, rule->right);
    CGRect r = UIEdgeInsetsInsetRect(b, ins);
    if (r.size.width < 4.0 || r.size.height < 4.0) return;
    glass.frame = r;
    glass.layer.cornerRadius = rule->radius < 0.0 ? r.size.height / 2.0 : rule->radius;
    UIView *tint = [glass.contentView viewWithTag:0x6767];
    tint.frame = glass.contentView.bounds;
    if (glass.superview != v) [v insertSubview:glass atIndex:0];
}

static void GGWalkAndSkin(UIView *root) {
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count > 0 && visited < 4000) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        visited++;
        @try { GGApplySkinToView(v); } @catch (__unused NSException *e) {}
        NSArray *subs = v.subviews;
        for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
            UIView *s = subs[(NSUInteger)i];
            if ([s isKindOfClass:[UIVisualEffectView class]]) continue;
            if (s.hidden || s.alpha < 0.01) continue;
            [stack addObject:s];
            if (stack.count > 4000) break;
        }
    }
}

static UIWindow *GGKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    UIWindow *fallback = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) return w;
        if (!fallback && w.windowLevel == UIWindowLevelNormal) fallback = w;
    }
    return fallback;
}

static dispatch_source_t gSkinTimer = NULL;

static void GGStartSkinTimer(void) {
    if (gSkinTimer) return;
    gSkinTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gSkinTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                              (uint64_t)(1.2 * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gSkinTimer, ^{
        @autoreleasepool {
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
            UIWindow *w = GGKeyWindow();
            if (!w) return;
            @try { GGWalkAndSkin(w); } @catch (__unused NSException *e) {}
        }
    });
    dispatch_resume(gSkinTimer);
}

#pragma mark - glow on like / favorite / collect

static const void *kGGGlowKey = &kGGGlowKey;
static NSMutableDictionary<NSString *, NSValue *> *gOrigMap = nil;

@interface GGGlowWatcher : NSObject
@end

@implementation GGGlowWatcher

+ (void)applyGlow:(BOOL)on to:(UIView *)v animated:(BOOL)animated {
    if (!v) return;
    UIColor *color = v.tintColor;
    if (!color || CGColorGetAlpha(color.CGColor) < 0.05) {
        color = [UIColor colorWithRed:1.0 green:0.17 blue:0.33 alpha:1.0];
    }
    CALayer *l = v.layer;
    l.shadowColor = color.CGColor;
    l.shadowOffset = CGSizeZero;
    l.shadowPath = [UIBezierPath bezierPathWithRoundedRect:v.bounds
                                              cornerRadius:v.bounds.size.height / 2.0].CGPath;
    if (animated) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
        a.fromValue = @(l.shadowOpacity);
        a.toValue = @(on ? 0.95 : 0.0);
        a.duration = 0.25;
        [l addAnimation:a forKey:@"gg_glow"];
    }
    l.shadowOpacity = on ? 0.95f : 0.0f;
    l.shadowRadius = on ? 13.0 : 6.0;

    if (on && animated) {
        CAKeyframeAnimation *p = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        p.values = @[@1.0, @1.32, @0.94, @1.0];
        p.keyTimes = @[@0.0, @0.35, @0.70, @1.0];
        p.duration = 0.42;
        [v.layer addAnimation:p forKey:@"gg_pulse"];
    }
}

- (void)controlTapped:(UIControl *)sender {
    __weak UIControl *weakButton = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIControl *btn = weakButton;
        if (!btn) return;
        [GGGlowWatcher applyGlow:btn.selected to:btn animated:YES];
    });
}

- (void)viewTapped:(UITapGestureRecognizer *)gr {
    UIView *v = gr.view;
    if (!v) return;
    BOOL on = NO;
    @try { on = [[v valueForKey:@"selected"] boolValue]; } @catch (__unused NSException *e) {}
    [GGGlowWatcher applyGlow:on to:v animated:YES];
}

@end

static GGGlowWatcher *GGGlowWatcherShared(void) {
    static GGGlowWatcher *w = nil;
    if (!w) w = [GGGlowWatcher new];
    return w;
}

static void GGAttachGlow(UIView *v) {
    if (!v) return;
    if (objc_getAssociatedObject(v, kGGGlowKey)) return;
    objc_setAssociatedObject(v, kGGGlowKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([v isKindOfClass:[UIControl class]]) {
        [(UIControl *)v addTarget:GGGlowWatcherShared()
                           action:@selector(controlTapped:)
                 forControlEvents:UIControlEventTouchUpInside];
    } else {
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:GGGlowWatcherShared()
                                                                           action:@selector(viewTapped:)];
        t.cancelsTouchesInView = NO;
        [v addGestureRecognizer:t];
    }

    BOOL on = NO;
    @try { on = [[v valueForKey:@"selected"] boolValue]; } @catch (__unused NSException *e) {}
    [GGGlowWatcher applyGlow:on to:v animated:NO];
}

static void GGGrabButtonsFromElement(id element) {
    if (!element) return;
    for (NSString *key in @[@"likeButton", @"favoriteButton", @"collectButton",
                            @"diggButton", @"likeView", @"favoriteView"]) {
        id value = nil;
        @try { value = [element valueForKey:key]; } @catch (__unused NSException *e) { continue; }
        if ([value isKindOfClass:[UIView class]]) GGAttachGlow((UIView *)value);
    }
}

static IMP GGOrigIMPFor(id self, SEL cmd) {
    if (!gOrigMap) return NULL;
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(c), sel_getName(cmd)];
        NSValue *value = gOrigMap[key];
        if (value) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void GGElementHook0(id self, SEL _cmd) {
    IMP orig = GGOrigIMPFor(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);
    @try { GGGrabButtonsFromElement(self); } @catch (__unused NSException *e) {}
}

static void GGElementHook1(id self, SEL _cmd, id arg) {
    IMP orig = GGOrigIMPFor(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, arg);
    @try { GGGrabButtonsFromElement(self); } @catch (__unused NSException *e) {}
}

static void GGHookClassSel(Class cls, SEL sel, IMP hook) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    NSString *key = [NSString stringWithFormat:@"%s::%s", class_getName(cls), sel_getName(sel)];
    gOrigMap[key] = [NSValue valueWithPointer:method_getImplementation(m)];
    method_setImplementation(m, hook);
}

static void GGHookGlowTargets(void) {
    if (!gOrigMap) gOrigMap = [NSMutableDictionary dictionary];
    NSArray *classNames = @[@"AWEPlayInteractionLikeElement",
                            @"TTKPlayInteractionLikeElement",
                            @"TTKPlayInteractionFavoriteElement",
                            @"AWEPlayInteractionFavoriteElement",
                            @"TTKDetailCollectionCollectButtonViewComponent"];
    int hooked = 0;
    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        for (NSString *selName in @[@"componentViewDidLoad", @"updateWithModel:", @"bindEvent", @"componentMount"]) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            NSUInteger args = method_getNumberOfArguments(m);
            GGHookClassSel(cls, sel, args >= 3 ? (IMP)GGElementHook1 : (IMP)GGElementHook0);
            hooked++;
        }
        GGLog(@"glow: %@ hooked", name);
    }
    GGLog(@"glow: %d methods hooked", hooked);
}

#pragma mark - hierarchy dump (discovery of unknown Swift classes)

static void GGDumpHierarchy(NSString *tag) {
    UIWindow *w = GGKeyWindow();
    if (!w) { GGLog(@"dump %@: no window", tag); return; }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"GTokGlass hierarchy (%@) iOS %@\n", tag, [UIDevice currentDevice].systemVersion];

    NSMutableArray *queue = [NSMutableArray array];
    [queue addObject:@[w, @0]];
    NSUInteger idx = 0;
    NSInteger budget = 6000;
    while (idx < queue.count && budget-- > 0 && out.length < 900000) {
        NSArray *pair = queue[idx++];
        UIView *v = pair[0];
        NSInteger depth = [pair[1] integerValue];
        CGRect f = [w convertRect:v.bounds fromView:v];
        [out appendFormat:@"%*s%@  (%.0f,%.0f %.0fx%.0f)%@%@\n",
         (int)(depth * 2), "", NSStringFromClass([v class]),
         f.origin.x, f.origin.y, f.size.width, f.size.height,
         v.hidden ? @" hidden" : @"",
         v.alpha < 0.99 ? [NSString stringWithFormat:@" alpha=%.2f", v.alpha] : @""];
        if (depth >= 14) continue;
        for (UIView *s in v.subviews) [queue addObject:@[s, @(depth + 1)]];
    }

    NSString *path = [GGDir() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"hierarchy_%@.txt", tag]];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    GGLog(@"hierarchy dump -> %@ (%lu views)", path.lastPathComponent, (unsigned long)queue.count);
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
        if (!window) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isKeyWindow) { window = w; break; }
                if (!window && w.windowLevel == UIWindowLevelNormal) window = w;
            }
        }
        if (!window) { GGLog(@"capsule: no window"); return; }
        GGLog(@"capsule: shown in %@", NSStringFromClass([window class]));

        UIVisualEffectView *capsule = [[UIVisualEffectView alloc] initWithEffect:GGGlassEffect()];
        capsule.translatesAutoresizingMaskIntoConstraints = NO;
        capsule.layer.cornerRadius = 18;
        capsule.clipsToBounds = YES;
        // guarantee visibility even if the glass effect renders empty
        capsule.contentView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.78];
        capsule.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        capsule.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;

        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = text;
        label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        label.textColor = [UIColor whiteColor];
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
            [UIView animateWithDuration:0.4 delay:4.0 options:0 animations:^{ capsule.alpha = 0; } completion:^(BOOL finished2) {
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
                                  @"tabBarCapsule": @YES,
                                  @"glassSkin": @YES,
                                  @"skipScopes": GGDefaultSkinSkipScopes(),
                                  @"dumpHierarchy": @YES,
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
    [fm createFileAtPath:gLogPath contents:[NSData data] attributes:nil];
    gLogLock = [NSLock new];
    gLogEnabled = [cfg[@"log"] boolValue];

    if (![cfg[@"enabled"] boolValue]) {
        GGLog(@"disabled via config, doing nothing");
        return;
    }

    UIDevice *dev = [UIDevice currentDevice];
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    GGLog(@"GTokGlass 0.6 | iOS %@ | %@ | TikTok %@ (%@)",
          dev.systemVersion, dev.model,
          info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]);
    GGLog(@"UIDesignRequiresCompatibility=%@", info[@"UIDesignRequiresCompatibility"] ?: @"<nil>");
    GGLog(@"main bundle: %@", [[NSBundle mainBundle] bundlePath]);

    int flags = 0, ab = 0;

    if ([cfg[@"nativeGlass"] boolValue]) {
        GGForceCapabilityGate();
        flags = GGForceTUXExperiments();
        GGHookButtonSetup();
        GGHookConfigCenter();
        GGDumpGlassClasses();
    }
    if ([cfg[@"abGlass"] boolValue]) {
        ab = GGForceABFlags();
    }

    gTabBarGlass = [cfg[@"tabBarGlass"] boolValue];
    gTabBarCapsule = [cfg[@"tabBarCapsule"] boolValue];
    if (gTabBarCapsule) gTabBarGlass = NO;
    GGLog(@"tab bar: capsule=%d glass=%d", (int)gTabBarCapsule, (int)gTabBarGlass);
    GGSetupTabBarGlass();

    gGlassSkin = [cfg[@"glassSkin"] boolValue];
    gSkinSkipScopes = [cfg[@"skipScopes"] isKindOfClass:[NSArray class]]
                          ? cfg[@"skipScopes"]
                          : GGDefaultSkinSkipScopes();
    if (gGlassSkin) {
        GGStartSkinTimer();
        GGHookGlowTargets();
        GGLog(@"glass skin: on (%lu rules, skip: %@)",
              (unsigned long)(sizeof(gSkinRules) / sizeof(gSkinRules[0])),
              [gSkinSkipScopes componentsJoinedByString:@", "]);
    } else {
        GGLog(@"glass skin: off");
    }

    if ([cfg[@"dumpHierarchy"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ GGDumpHierarchy(@"start"); });
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            GGDumpHierarchy(@"bg");
        }];
        GGLog(@"hierarchy dump: armed (start + background)");
    }

    int ok = (NSClassFromString(@"_TtC12TUXSwiftBase14TUXExperiments") != Nil);
    if ([cfg[@"showStatus"] boolValue]) {
        NSString *text = ok ? [NSString stringWithFormat:@"GTokGlass 0.6 | flags %d | ab %d", flags, ab]
                            : @"GTokGlass 0.6 | class not found";
        GGShowStatus(text);
    }
    GGLog(@"done (entries=%d)", gEntCount);
}

__attribute__((constructor))
static void GTokGlassInit(void) {
    @autoreleasepool {
        GGBootstrap();
    }
}
