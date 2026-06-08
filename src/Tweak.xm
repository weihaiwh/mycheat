#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v5.0 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//
//  关键修复:
//  1. GameAssembly.dylib 在 constructor 时可能还没加载
//     → 用 dispatch_after 轮询等待
//  2. plist 必须是 XML 格式 (不是 NeXTSTEP)
//  3. 触摸穿透: hitTest 只拦截按钮/面板区域
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

static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) return true;
    return orig_CheckSkillIsReady(frame, stateType, void *characterField, states);
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
            NSLog(@"[WHWB] GameAssembly found: %s base=0x%lx", name, base);
            return base;
        }
    }
    return 0;
}

#pragma mark - 安装 Hooks (延迟调用)

static void installHooks() {
    if (g_hooksInstalled) return;

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        NSLog(@"[WHWB] GameAssembly not loaded yet, will retry...");
        return;
    }
    NSLog(@"[WHWB] GameAssembly base: 0x%lx, installing hooks...", base);

    // 读取前几字节验证地址有效 (防止 hook 到错误位置)
    void *addrAttack = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    void *addrReady = (void *)(base + OFFSET_CHECK_SKILL_READY);
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);

    NSLog(@"[WHWB] Hook addresses: Attack=%p Ready=%p LimitDmg=%p", addrAttack, addrReady, addrLimitDmg);

    MSHookFunction(addrAttack, (void *)hook_CheckSkillAttackCanUse, (void **)&orig_CheckSkillAttackCanUse);
    MSHookFunction(addrReady, (void *)hook_CheckSkillIsReady, (void **)&orig_CheckSkillIsReady);
    MSHookFunction(addrLimitDmg, (void *)hook_get_limitDamage, (void **)&orig_get_limitDamage);

    g_hooksInstalled = YES;
    NSLog(@"[WHWB] All 3 hooks installed OK!");

    // 默认开启
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;
    g_patchLimitDamage = YES;
}

#pragma mark - 触摸穿透容器

@interface WHWBPassthroughView : UIView
@end
@implementation WHWBPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil; // 空白区域穿透
    return hit;
}
@end

#pragma mark - 悬浮窗

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

    // 浮动按钮 (小圆点, 不遮挡游戏)
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 36, 36);
    self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.8];
    self.toggleButton.layer.cornerRadius = 18;
    self.toggleButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toggleButton.layer.shadowOffset = CGSizeMake(0, 1);
    self.toggleButton.layer.shadowOpacity = 0.5;
    self.toggleButton.layer.shadowRadius = 3;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.toggleButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    // 拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleButton addGestureRecognizer:pan];
    [self addSubview:self.toggleButton];

    // 面板 (默认隐藏)
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 42, 250, 290)];
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
    title.text = @"WHWB Helper v5.0";
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

    // Switches
    y = [self makeSwitch:y x:x w:w label:@"AttackCanUse -> true" on:NO action:@selector(toggleAttack:) tint:[UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0] sw:&_swAttack];
    y = [self makeSwitch:y x:x w:w label:@"IsReady -> true" on:NO action:@selector(toggleReady:) tint:[UIColor colorWithRed:1.0 green:0.55 blue:0.1 alpha:1.0] sw:&_swReady];

    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(x, y+2, w, 0.5)];
    sep2.backgroundColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep2];
    y += 8;

    y = [self makeSwitch:y x:x w:w label:@"limitDamage = 131072000" on:NO action:@selector(toggleLimitDmg:) tint:[UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0] sw:&_swLimitDmg];

    y += 8;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 36)];
    self.statusLabel.text = @"Waiting for hooks...";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.numberOfLines = 0;
    [self.panelView addSubview:self.statusLabel];
}

- (CGFloat)makeSwitch:(CGFloat)y x:(CGFloat)x w:(CGFloat)w label:(NSString *)label on:(BOOL)on action:(SEL)action tint:(UIColor *)tint sw:(UISwitch *WHWBMenuView::* *)swPtr {
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    s.on = on;
    s.onTintColor = tint;
    s.transform = CGAffineTransformMakeScale(0.75, 0.75);
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:s];

    if (swPtr == &_swAttack) self.swAttack = s;
    else if (swPtr == &_swReady) self.swReady = s;
    else if (swPtr == &_swLimitDmg) self.swLimitDmg = s;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x + 44, y + 5, w - 44, 20)];
    lbl.text = label;
    lbl.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:lbl];

    return y + 32;
}

- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panelView.hidden = !self.panelVisible;
    if (self.panelVisible) {
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.9 green:0.2 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.85];
        [self.toggleButton setTitle:@"X" forState:UIControlStateNormal];
    } else {
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.8];
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

- (void)toggleAttack:(UISwitch *)s { g_patchSkillAttack = s.isOn; [self refreshStatus]; }
- (void)toggleReady:(UISwitch *)s { g_patchSkillReady = s.isOn; [self refreshStatus]; }
- (void)toggleLimitDmg:(UISwitch *)s { g_patchLimitDamage = s.isOn; [self refreshStatus]; }

- (void)refreshStatus {
    if (!g_hooksInstalled) {
        self.statusLabel.text = @"Hooks NOT installed!";
        self.statusLabel.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.2 alpha:1.0];
        return;
    }
    NSMutableArray *a = [NSMutableArray array];
    if (g_patchSkillAttack) [a addObject:@"Atk"];
    if (g_patchSkillReady) [a addObject:@"Ready"];
    if (g_patchLimitDamage) [a addObject:@"Dmg"];
    if (a.count) {
        self.statusLabel.text = [NSString stringWithFormat:@"ON: %@", [a componentsJoinedByString:@", "]];
        self.statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
    } else {
        self.statusLabel.text = @"All OFF";
        self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    }
}

// 外部调用: hooks 安装完成后更新 UI
- (void)onHooksInstalled {
    self.swAttack.on = g_patchSkillAttack;
    self.swReady.on = g_patchSkillReady;
    self.swLimitDmg.on = g_patchLimitDamage;
    [self refreshStatus];
}

@end

#pragma mark - 全局引用

static WHWBMenuView *g_menuView = nil;
static int g_retryCount = 0;

#pragma mark - 显示悬浮窗

static void showMenu() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_menuView) return;

        UIWindow *keyWindow = nil;

        // iOS 13+ UIScene
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    keyWindow = scene.windows.firstObject;
                    break;
                }
            }
        }
        // Fallback
        if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        }
        // 再 fallback: 创建新 window
        if (!keyWindow) {
            keyWindow = [[UIApplication sharedApplication].delegate window];
        }
        if (!keyWindow) {
            NSLog(@"[WHWB] ERROR: No keyWindow found!");
            return;
        }

        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 260, 340)];
        g_menuView.alpha = 0;
        [keyWindow addSubview:g_menuView];

        [UIView animateWithDuration:0.3 animations:^{
            g_menuView.alpha = 1.0;
        }];

        // 如果 hooks 已经装好了，更新 UI
        if (g_hooksInstalled) {
            [g_menuView onHooksInstalled];
        }

        NSLog(@"[WHWB] Menu shown on window: %@", keyWindow);
    });
}

#pragma mark - 轮询等待 GameAssembly + 安装 hooks

static void tryInstallHooks();

static void tryInstallHooks() {
    if (g_hooksInstalled) return;

    g_retryCount++;
    NSLog(@"[WHWB] tryInstallHooks attempt #%d, images=%u", g_retryCount, _dyld_image_count());

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        if (g_retryCount < 60) { // 最多重试 60 次 (30 秒)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                tryInstallHooks();
            });
        } else {
            NSLog(@"[WHWB] ERROR: GameAssembly not found after 30s, giving up");
            if (g_menuView) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    g_menuView.statusLabel.text = @"FAILED: GameAssembly not found";
                    g_menuView.statusLabel.textColor = [UIColor redColor];
                });
            }
        }
        return;
    }

    // GameAssembly 找到了，安装 hooks
    installHooks();

    // 更新 UI
    if (g_menuView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_menuView onHooksInstalled];
        });
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void whwb_init() {
    NSLog(@"[WHWB] ====================================");
    NSLog(@"[WHWB] WHWB Helper v5.0 loaded");
    NSLog(@"[WHWB] Target: com.jyjh.whwb v1.10.1");
    NSLog(@"[WHWB] ====================================");

    // 延迟 2 秒后开始: 1) 显示 UI  2) 轮询等待 GameAssembly 加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();
        tryInstallHooks();
    });
}
