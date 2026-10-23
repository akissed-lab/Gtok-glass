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
static UIView *(*gOrigTabBarLayout)(id, SEL) = NULL;

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
    for (NSString *key in @[@"bgView", @"backgroundView"]) {
        @try {
            UIView *v = [bar valueForKey:key];
            if ([v isKindOfClass:[UIView class]]) v.hidden = YES;
        } @catch (__unused NSException *e) {}
    }
}

static void GGReplacementTabBarLayout(id self, SEL _cmd) {
    if (gOrigTabBarLayout) gOrigTabBarLayout(self, _cmd);
    @try { GGApplyTabBarGlass((UIView *)self); } @catch (__unused NSException *e) {}
}

static void GGSetupTabBarGlass(void) {
    if (!gTabBarGlass) return;
    Class cls = GGClassWithSuffix(@"TTKTabBar");
    if (!cls) { GGLog(@"TTKTabBar: class NOT found"); return; }
    SEL sel = sel_registerName("layoutSubviews");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    gOrigTabBarLayout = (UIView *(*)(id, SEL))method_getImplementation(m);
    method_setImplementation(m, (IMP)GGReplacementTabBarLayout);
    GGLog(@"TTKTabBar: own glass background enabled");
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
    GGLog(@"GTokGlass 0.2 | iOS %@ | %@ | TikTok %@ (%@)",
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
    GGSetupTabBarGlass();

    int ok = (NSClassFromString(@"_TtC12TUXSwiftBase14TUXExperiments") != Nil);
    if ([cfg[@"showStatus"] boolValue]) {
        NSString *text = ok ? [NSString stringWithFormat:@"GTokGlass 0.2 | flags %d | ab %d", flags, ab]
                            : @"GTokGlass 0.2 | class not found";
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
