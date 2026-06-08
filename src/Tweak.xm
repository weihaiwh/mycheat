#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v6.0 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless / TrollStore
//
//  v6.0 关键修复 (vs v5.0):
//  1. [BUG] hook_CheckSkillIsReady 函数调用里多了 "void *" 语法错误
//  2. [BUG] PLIST 旧 NeXTSTEP 格式 → 改为 XML 格式
//  3. [重构] 创建独立 UIWindow 做悬浮窗 (不再依赖 app 的 keyWindow)
//  4. [重构] 通知驱动初始化 (等 App 活跃后再创建 UI)
//  5. [重构] 简化 makeSwitch 方法，去掉成员指针
//  6. [兼容] TrollStore 注入: constructor 仅注册通知，不做任何 UIKit 操作
// ============================================================

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

// v5.0 BUG FIX: 函数调用里不能有 "void *"
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
            NSLog(@"[WHWB] GameAssembly found: %s base=0x%lx", name, (unsigned long)base);
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
        NSLog(@"[WHWB] GameAssembly not loaded yet");
        return;
    }
    NSLog(@"[WHWB] GameAssembly base: 0x%lx, installing hooks...", (unsigned long)base);

    void *addrAttack  = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    void *addrReady   = (void *)(base + OFFSET_CHECK_SKILL_READY);
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);

    NSLog(@"[WHWB] Hook addresses: Attack=%p Ready=%p LimitDmg=%p", addrAttack, addrReady, addrLimitDmg);

    MSHookFunction(addrAttack,  (void *)hook_CheckSkillAttackCanUse, (void **)&orig_CheckSkillAttackCanUse);
    MSHookFunction(addrReady,   (void *)hook_CheckSkillIsReady,      (void **)&orig_CheckSkillIsReady);
    MSHookFunction(addrLimitDmg,(void *)hook_get_limitDamage,        (void **)&orig_get_limitDamage);

    g_hooksInstalled = YES;
    // 默认全部开启
    g_patchSkillAttack = YES;
    g_patchSkillReady  = YES;
    g_patchLimitDamage = YES;
    NSLog(@"[WHWB] All 3 hooks installed OK!");
}

#pragma mark - 触摸穿透 Window (核心: 独立 UIWindow 不挡触摸)

@interface WHWBPassthroughWindow : UIWindow
@end

@implementation WHWBPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 只有点到按钮/面板等子视图才拦截
    // 空白区域 (window 自身或 rootVC.view) → 穿透
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
    if (hit == self) return nil; // 空白区域穿透
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

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 22)];
    title.text = @"WHWB Helper v6.0";
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

    // Switch 行 (v6.0: 简化方法, 不用成员指针)
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

#pragma mark - 创建悬浮窗 (核心: 使用独立 UIWindow)

static void showMenu() {
    if (g_menuView) return;

    NSLog(@"[WHWB] showMenu: creating overlay window...");

    UIWindow *overlayWindow = nil;

    // iOS 13+: 优先用 UIWindowScene 创建 (才能显示在 Scene 里)
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                overlayWindow = [[WHWBPassthroughWindow alloc] initWithWindowScene:scene];
                NSLog(@"[WHWB] Created window with scene: %@", scene);
                break;
            }
        }
    }

    // Fallback: 不用 scene (iOS 12 以下或 scene 未就绪)
    if (!overlayWindow) {
        overlayWindow = [[WHWBPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        NSLog(@"[WHWB] Created window without scene (fallback)");
    }

    overlayWindow.frame = [UIScreen mainScreen].bounds;
    overlayWindow.backgroundColor = [UIColor clearColor];
    overlayWindow.windowLevel = UIWindowLevelNormal + 200;  // 高于普通 window
    overlayWindow.clipsToBounds = NO;

    // rootViewController + passthrough view
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = [[WHWBPassthroughView alloc] initWithFrame:overlayWindow.bounds];
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;

    // 菜单
    g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 260, 340)];
    [vc.view addSubview:g_menuView];

    overlayWindow.rootViewController = vc;
    overlayWindow.hidden = NO;  // 不用 makeKeyAndVisible，不抢键盘焦点

    g_overlayWindow = (WHWBPassthroughWindow *)overlayWindow;

    if (g_hooksInstalled) {
        [g_menuView onHooksInstalled];
    }

    NSLog(@"[WHWB] Overlay window created! level=%.0f frame=%@",
          overlayWindow.windowLevel,
          NSStringFromCGRect(overlayWindow.frame));
}

#pragma mark - 轮询等待 GameAssembly + 安装 hooks

static void tryInstallHooks();

static void tryInstallHooks() {
    if (g_hooksInstalled) return;

    g_hookRetryCount++;
    NSLog(@"[WHWB] tryInstallHooks attempt #%d, images=%u", g_hookRetryCount, _dyld_image_count());

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        if (g_hookRetryCount < 60) { // 最多 30 秒
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                tryInstallHooks();
            });
        } else {
            NSLog(@"[WHWB] ERROR: GameAssembly not found after 30s, giving up");
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
        NSLog(@"[WHWB] EXCEPTION in installHooks: %@", e);
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

#pragma mark - 延迟初始化 (App 活跃后)

static void delayedInit() {
    NSLog(@"[WHWB] delayedInit: creating menu and starting hook poll...");

    @try {
        showMenu();
    } @catch (NSException *e) {
        NSLog(@"[WHWB] EXCEPTION in showMenu: %@", e);
    }

    // 无论菜单是否成功，都尝试安装 hooks
    tryInstallHooks();
}

#pragma mark - 入口

__attribute__((constructor))
static void whwb_init() {
    NSLog(@"[WHWB] ====================================");
    NSLog(@"[WHWB] WHWB Helper v6.0 loaded");
    NSLog(@"[WHWB] Target: com.jyjh.whwb v1.10.1");
    NSLog(@"[WHWB] ====================================");

    // === 关键: constructor 里只注册通知，不做任何 UIKit 操作 ===
    // 这样无论 MobileSubstrate 还是 TrollStore 注入都不会闪退

    // 方案1: 等 App 变活跃再初始化 (最安全)
    __block id activeObserver = nil;
    activeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
        activeObserver = nil;
        NSLog(@"[WHWB] App became active, starting init...");

        // 等 1 秒让 App UI 稳定
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            delayedInit();
        });
    }];

    // 方案2: 保底 fallback — 如果通知没触发 (5秒后)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_menuView) {
            NSLog(@"[WHWB] Fallback: notification never fired, trying init anyway...");
            if (activeObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
                activeObserver = nil;
            }
            delayedInit();
        }
    });
}
