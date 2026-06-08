#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v6.1 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//
//  v6.1 vs v6.0:
//  + 文件日志: 所有 NSLog 同时写入 /var/mobile/Documents/whwb.log
//  + 诊断信息: 构造函数执行、dylib 加载、通知触发、UI 创建、hooks 安装
//  + 更强健的 UI 创建: 多种 fallback 方案
// ============================================================

#pragma mark - 文件日志 (关键! 写到手机上方便排查)

static NSString *LOG_PATH = @"/var/mobile/Documents/whwb.log";

static void fileLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void fileLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    // 同时 NSLog (系统日志)
    NSLog(@"[WHWB] %@", msg);

    // 写入文件 (追加模式)
    NSDate *now = [NSDate date];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *ts = [df stringFromDate:now];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", ts, msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        // 文件不存在，创建
        [line writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // 设置权限让 mobile 用户可读写
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0666)}
                                         ofItemAtPath:LOG_PATH
                                                error:nil];
    }
}

#pragma mark - 偏移量 (v1.10.1 dump.cs RVA)
static uintptr_t OFFSET_CHECK_SKILL_ATTACK  = 0x30741b8;
static uintptr_t OFFSET_CHECK_SKILL_READY    = 0x3074b54;
static uintptr_t OFFSET_GET_LIMIT_DAMAGE     = 0x30a2f70;

#pragma mark - 全局状态
static BOOL g_patchSkillAttack = NO;
static BOOL g_patchSkillReady  = NO;
static BOOL g_patchLimitDamage = NO;
static BOOL g_hooksInstalled = NO;
static int32_t TARGET_LIMIT_DAMAGE = 131072000;

#pragma mark - Hook 函数声明

static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *characterField, void *states);
static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *characterField, void *states);
static int32_t (*orig_get_limitDamage)(void *self);

static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillAttack) return true;
    return orig_CheckSkillAttackCanUse(frame, stateType, characterField, states);
}

static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) return true;
    return orig_CheckSkillIsReady(frame, stateType, characterField, states);
}

static int32_t hook_get_limitDamage(void *self) {
    if (g_patchLimitDamage) return TARGET_LIMIT_DAMAGE;
    return orig_get_limitDamage(self);
}

#pragma mark - 获取 GameAssembly.dylib 基址

static uintptr_t getGameAssemblyBase() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "GameAssembly")) {
            uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
            fileLog(@"GameAssembly found: %s base=0x%lx (image #%u)", name, (unsigned long)base, i);
            return base;
        }
    }
    return 0;
}

#pragma mark - 安装 Hooks

static void installHooks() {
    if (g_hooksInstalled) return;

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        fileLog(@"GameAssembly not loaded yet");
        return;
    }
    fileLog(@"GameAssembly base: 0x%lx, installing hooks...", (unsigned long)base);

    void *addrAttack  = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    void *addrReady   = (void *)(base + OFFSET_CHECK_SKILL_READY);
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);

    fileLog(@"Hook addresses: Attack=%p Ready=%p LimitDmg=%p", addrAttack, addrReady, addrLimitDmg);

    MSHookFunction(addrAttack,  (void *)hook_CheckSkillAttackCanUse, (void **)&orig_CheckSkillAttackCanUse);
    MSHookFunction(addrReady,   (void *)hook_CheckSkillIsReady,      (void **)&orig_CheckSkillIsReady);
    MSHookFunction(addrLimitDmg,(void *)hook_get_limitDamage,        (void **)&orig_get_limitDamage);

    g_hooksInstalled = YES;
    g_patchSkillAttack = YES;
    g_patchSkillReady  = YES;
    g_patchLimitDamage = YES;
    fileLog(@"All 3 hooks installed OK!");
}

#pragma mark - 触摸穿透 Window

@interface WHWBPassthroughWindow : UIWindow
@end

@implementation WHWBPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - 触摸穿透容器 View

@interface WHWBPassthroughView : UIView
@end

@implementation WHWBPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}
@end

#pragma mark - 悬浮窗菜单

@interface WHWBMenuView : WHWBPassthroughView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISwitch *swAttack;
@property (nonatomic, strong) UISwitch *swReady;
@property (nonatomic, strong) UISwitch *swLimitDmg;
@property (nonatomic, assign) BOOL panelVisible;
@end

@implementation WHWBMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = NO;
    self.panelVisible = NO;

    // ---- 浮动按钮 (小圆点) ----
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 36, 36);
    self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.85];
    self.toggleButton.layer.cornerRadius = 18;
    self.toggleButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toggleButton.layer.shadowOffset = CGSizeMake(0, 1);
    self.toggleButton.layer.shadowOpacity = 0.5;
    self.toggleButton.layer.shadowRadius = 3;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.toggleButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleButton addGestureRecognizer:pan];
    [self addSubview:self.toggleButton];

    // ---- 面板 (默认隐藏) ----
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 42, 250, 280)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.12 alpha:0.95];
    self.panelView.layer.cornerRadius = 12;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.5].CGColor;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.clipsToBounds = YES;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];

    [self setupPanel];
    return self;
}

- (void)setupPanel {
    CGFloat y = 10, x = 10, w = 230;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 22)];
    title.text = @"WHWB Helper v6.1";
    title.textColor = [UIColor colorWithRed:0.35 green:0.7 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 26;

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 13)];
    ver.text = @"GameAssembly.dylib hook";
    ver.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    ver.font = [UIFont systemFontOfSize:10];
    ver.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:ver];
    y += 18;

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 0.5)];
    sep.backgroundColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep];
    y += 8;

    self.swAttack = [self addSwitchAt:y x:x w:w label:@"AttackCanUse -> true" on:NO tint:[UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0] action:@selector(toggleAttack:)];
    y += 34;

    self.swReady = [self addSwitchAt:y x:x w:w label:@"IsReady -> true" on:NO tint:[UIColor colorWithRed:1.0 green:0.55 blue:0.1 alpha:1.0] action:@selector(toggleReady:)];
    y += 34;

    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 0.5)];
    sep2.backgroundColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep2];
    y += 8;

    self.swLimitDmg = [self addSwitchAt:y x:x w:w label:@"limitDamage=131072000" on:NO tint:[UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0] action:@selector(toggleLimitDmg:)];
    y += 42;

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 40)];
    self.statusLabel.text = @"Waiting for hooks...";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.numberOfLines = 0;
    [self.panelView addSubview:self.statusLabel];
}

- (UISwitch *)addSwitchAt:(CGFloat)y x:(CGFloat)x w:(CGFloat)w
                    label:(NSString *)label on:(BOOL)on
                     tint:(UIColor *)tint action:(SEL)action {
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    s.on = on;
    s.onTintColor = tint;
    s.transform = CGAffineTransformMakeScale(0.75, 0.75);
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:s];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x + 44, y + 5, w - 44, 20)];
    lbl.text = label;
    lbl.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:lbl];

    return s;
}

- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panelView.hidden = !self.panelVisible;
    if (self.panelVisible) {
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.9 green:0.2 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.85];
        [self.toggleButton setTitle:@"X" forState:UIControlStateNormal];
    } else {
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.85];
        [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = self.center;
    c.x += t.x; c.y += t.y;
    CGSize s = [UIScreen mainScreen].bounds.size;
    c.x = MAX(18, MIN(s.width - 18, c.x));
    c.y = MAX(24, MIN(s.height - 24, c.y));
    self.center = c;
    [g setTranslation:CGPointZero inView:self.superview];
}

- (void)toggleAttack:(UISwitch *)s   { g_patchSkillAttack  = s.isOn; [self refreshStatus]; }
- (void)toggleReady:(UISwitch *)s    { g_patchSkillReady   = s.isOn; [self refreshStatus]; }
- (void)toggleLimitDmg:(UISwitch *)s { g_patchLimitDamage  = s.isOn; [self refreshStatus]; }

- (void)refreshStatus {
    if (!g_hooksInstalled) {
        self.statusLabel.text = @"Hooks NOT installed yet...";
        self.statusLabel.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.2 alpha:1.0];
        return;
    }
    NSMutableArray *a = [NSMutableArray array];
    if (g_patchSkillAttack)  [a addObject:@"Atk"];
    if (g_patchSkillReady)   [a addObject:@"Ready"];
    if (g_patchLimitDamage)  [a addObject:@"Dmg"];
    if (a.count) {
        self.statusLabel.text = [NSString stringWithFormat:@"Active: %@", [a componentsJoinedByString:@", "]];
        self.statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
    } else {
        self.statusLabel.text = @"All OFF";
        self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    }
}

- (void)onHooksInstalled {
    self.swAttack.on  = g_patchSkillAttack;
    self.swReady.on   = g_patchSkillReady;
    self.swLimitDmg.on = g_patchLimitDamage;
    [self refreshStatus];
}

@end

#pragma mark - 全局引用

static WHWBPassthroughWindow *g_overlayWindow = nil;
static WHWBMenuView *g_menuView = nil;
static int g_hookRetryCount = 0;

#pragma mark - 诊断: 列出所有 loaded images

static void dumpLoadedImages() {
    fileLog(@"=== Loaded images (%u) ===", _dyld_image_count());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "GameAssembly") || strstr(name, "WHWB") || strstr(name, "whwb") || strstr(name, "jyjh"))) {
            fileLog(@"  [%u] %s base=0x%lx", i, name, (unsigned long)_dyld_get_image_header(i));
        }
    }
    fileLog(@"=== End images ===");
}

#pragma mark - 诊断: 检查 UIApplication 状态

static void dumpAppState() {
    UIApplication *app = [UIApplication sharedApplication];
    fileLog(@"AppState: app=%p", app);
    if (app) {
        fileLog(@"  applicationState=%ld", (long)app.applicationState);
        fileLog(@"  connectedScenes count=%lu", (unsigned long)app.connectedScenes.count);
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in app.connectedScenes) {
                fileLog(@"  scene: %@ state=%ld windows=%lu",
                        scene.title ?: @"(nil)",
                        (long)scene.activationState,
                        (unsigned long)scene.windows.count);
                for (UIWindow *w in scene.windows) {
                    fileLog(@"    window: %p level=%.0f frame=%@ hidden=%d",
                            w, w.windowLevel, NSStringFromCGRect(w.frame), w.hidden);
                }
            }
        }
        fileLog(@"  keyWindow=%p", app.keyWindow);
        fileLog(@"  windows count=%lu", (unsigned long)app.windows.count);
        for (UIWindow *w in app.windows) {
            fileLog(@"    window: %p level=%.0f frame=%@ hidden=%d",
                    w, w.windowLevel, NSStringFromCGRect(w.frame), w.hidden);
        }
    }
}

#pragma mark - 创建悬浮窗 (多种 fallback)

static void showMenu() {
    if (g_menuView) {
        fileLog(@"showMenu: menu already exists, skip");
        return;
    }

    fileLog(@"showMenu: creating overlay window...");

    UIWindow *overlayWindow = nil;

    // 方案A: iOS 13+ 用 UIWindowScene
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            fileLog(@"  trying scene: state=%ld", (long)scene.activationState);
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                overlayWindow = [[WHWBPassthroughWindow alloc] initWithWindowScene:scene];
                fileLog(@"  created window WITH scene: %p", overlayWindow);
                break;
            }
        }
    }

    // 方案B: 直接 initWithFrame (不依赖 scene)
    if (!overlayWindow) {
        overlayWindow = [[WHWBPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        fileLog(@"  created window WITHOUT scene (fallback): %p", overlayWindow);
    }

    if (!overlayWindow) {
        fileLog(@"FATAL: could not create any window!");
        return;
    }

    overlayWindow.frame = [UIScreen mainScreen].bounds;
    overlayWindow.backgroundColor = [UIColor clearColor];
    overlayWindow.windowLevel = UIWindowLevelNormal + 200;
    overlayWindow.clipsToBounds = NO;

    // rootViewController
    UIViewController *vc = [[UIViewController alloc] init];
    WHWBPassthroughView *containerView = [[WHWBPassthroughView alloc] initWithFrame:overlayWindow.bounds];
    containerView.backgroundColor = [UIColor clearColor];
    containerView.userInteractionEnabled = YES;
    vc.view = containerView;

    // 菜单
    g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 260, 340)];
    [containerView addSubview:g_menuView];

    overlayWindow.rootViewController = vc;

    // 关键: 不用 makeKeyAndVisible (不抢焦点), 直接设 hidden=NO
    overlayWindow.hidden = NO;

    g_overlayWindow = (WHWBPassthroughWindow *)overlayWindow;

    if (g_hooksInstalled) {
        [g_menuView onHooksInstalled];
    }

    fileLog(@"Overlay window created OK! level=%.0f frame=%@ windowPtr=%p menuPtr=%p",
          overlayWindow.windowLevel,
          NSStringFromCGRect(overlayWindow.frame),
          overlayWindow, g_menuView);

    // 诊断: 验证 window 是否在 app.windows 里
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fileLog(@"=== Post-create diagnostics ===");
        dumpAppState();
    });
}

#pragma mark - 轮询等待 GameAssembly + 安装 hooks

static void tryInstallHooks();

static void tryInstallHooks() {
    if (g_hooksInstalled) return;

    g_hookRetryCount++;
    fileLog(@"tryInstallHooks attempt #%d, images=%u", g_hookRetryCount, _dyld_image_count());

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        if (g_hookRetryCount < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                tryInstallHooks();
            });
        } else {
            fileLog(@"ERROR: GameAssembly not found after 30s, giving up");
            dumpLoadedImages();
            if (g_menuView) {
                g_menuView.statusLabel.text = @"FAILED: GameAssembly not found";
                g_menuView.statusLabel.textColor = [UIColor redColor];
            }
        }
        return;
    }

    @try {
        installHooks();
    } @catch (NSException *e) {
        fileLog(@"EXCEPTION in installHooks: %@", e);
        if (g_menuView) {
            g_menuView.statusLabel.text = [NSString stringWithFormat:@"Hook error: %@", e.reason];
            g_menuView.statusLabel.textColor = [UIColor redColor];
        }
        return;
    }

    if (g_menuView) {
        [g_menuView onHooksInstalled];
    }
}

#pragma mark - 延迟初始化

static void delayedInit() {
    fileLog(@"=== delayedInit START ===");

    // 诊断
    dumpAppState();
    dumpLoadedImages();

    @try {
        showMenu();
    } @catch (NSException *e) {
        fileLog(@"EXCEPTION in showMenu: %@", e);
    }

    tryInstallHooks();

    fileLog(@"=== delayedInit END ===");
}

#pragma mark - 入口

__attribute__((constructor))
static void whwb_init() {
    // 清空旧日志 (每次启动重新记录)
    [@"=== WHWB v6.1 Log Start ===\n" writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0666)}
                                     ofItemAtPath:LOG_PATH
                                            error:nil];

    fileLog(@"====================================");
    fileLog(@"WHWB Helper v6.1 constructor loaded");
    fileLog(@"Target: com.jyjh.whwb v1.10.1");
    fileLog(@"PID: %d", getpid());
    fileLog(@"====================================");

    // 列出已加载的 images (constructor 时可能还没有 GameAssembly)
    fileLog(@"Images at constructor time: %u", _dyld_image_count());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "GameAssembly") || strstr(name, "WHWB") || strstr(name, "jyjh"))) {
            fileLog(@"  [%u] %s", i, name);
        }
    }

    // 关键: constructor 里只注册通知
    // 等 UIApplicationDidBecomeActiveNotification 再初始化 UI

    __block id activeObserver = nil;
    activeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
        activeObserver = nil;
        fileLog(@"App became active notification received!");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            delayedInit();
        });
    }];

    fileLog(@"Registered UIApplicationDidBecomeActiveNotification observer: %p", activeObserver);

    // Fallback: 5秒后如果通知还没触发
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_menuView) {
            fileLog(@"Fallback: 5s timeout, notification never fired!");
            if (activeObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
                activeObserver = nil;
            }
            delayedInit();
        } else {
            fileLog(@"Fallback: menu already created, skip");
        }
    });

    fileLog(@"Constructor done, waiting for app activation...");
}
