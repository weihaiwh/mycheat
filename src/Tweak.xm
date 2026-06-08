#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v4.0 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//  Hook: CydiaSubstrate (MSHookFunction)
//  Fix: ASLR base = GameAssembly.dylib (not main binary!)
// ============================================================

#pragma mark - 偏移量 (v1.10.1 dump.cs RVA)
// IL2CPP 游戏的代码在 GameAssembly.dylib 里
// dump.cs 里的 RVA 是相对于 GameAssembly.dylib 的
static uintptr_t OFFSET_CHECK_SKILL_ATTACK  = 0x30741b8;
static uintptr_t OFFSET_CHECK_SKILL_READY    = 0x3074b54;
static uintptr_t OFFSET_GET_LIMIT_DAMAGE     = 0x30a2f70;

#pragma mark - 全局状态

static BOOL g_patchSkillAttack = NO;
static BOOL g_patchSkillReady  = NO;
static BOOL g_patchLimitDamage = NO;

// limitDamage 目标值 (Int32)
// 131072000 对应 AsLong = 2000
static int32_t TARGET_LIMIT_DAMAGE = 131072000;

#pragma mark - Hook: CheckSkillAttackCanUse

static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *characterField, void *states);

static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillAttack) return true;
    return orig_CheckSkillAttackCanUse(frame, stateType, characterField, states);
}

#pragma mark - Hook: CheckSkillIsReady

static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *characterField, void *states);

static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) return true;
    return orig_CheckSkillIsReady(frame, stateType, characterField, states);
}

#pragma mark - Hook: get_limitDamage (返回 Int32)

static int32_t (*orig_get_limitDamage)(void *self);

static int32_t hook_get_limitDamage(void *self) {
    if (g_patchLimitDamage) return TARGET_LIMIT_DAMAGE;
    return orig_get_limitDamage(self);
}

#pragma mark - 获取 GameAssembly.dylib 基址
// 关键修复: IL2CPP 游戏的代码在 GameAssembly.dylib 里
// dump.cs 的 RVA 是相对于这个 dylib 的

static uintptr_t getGameAssemblyBase() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "GameAssembly")) {
            uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[WHWB] GameAssembly.dylib found: %s base=0x%lx slide=0x%lx",
                  name, base, _dyld_get_image_vmaddr_slide(i));
            return base;
        }
    }
    NSLog(@"[WHWB] ERROR: GameAssembly.dylib not found in %u images!", _dyld_image_count());
    // 打印所有 image 帮助调试
    for (uint32_t i = 0; i < _dyld_image_count() && i < 20; i++) {
        NSLog(@"[WHWB]   image[%u]: %s", i, _dyld_get_image_name(i));
    }
    return 0;
}

#pragma mark - 安装所有 Hooks

static BOOL g_hooksInstalled = NO;

static void installHooks() {
    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        NSLog(@"[WHWB] ERROR: GameAssembly base is 0, hooks NOT installed");
        return;
    }
    NSLog(@"[WHWB] GameAssembly base: 0x%lx", base);

    // Hook CheckSkillAttackCanUse
    void *addrAttack = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    NSLog(@"[WHWB] Hooking CheckSkillAttackCanUse at %p (base+0x%lx)", addrAttack, OFFSET_CHECK_SKILL_ATTACK);
    MSHookFunction(addrAttack,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);

    // Hook CheckSkillIsReady
    void *addrReady = (void *)(base + OFFSET_CHECK_SKILL_READY);
    NSLog(@"[WHWB] Hooking CheckSkillIsReady at %p (base+0x%lx)", addrReady, OFFSET_CHECK_SKILL_READY);
    MSHookFunction(addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);

    // Hook get_limitDamage
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);
    NSLog(@"[WHWB] Hooking get_limitDamage at %p (base+0x%lx)", addrLimitDmg, OFFSET_GET_LIMIT_DAMAGE);
    MSHookFunction(addrLimitDmg,
                   (void *)hook_get_limitDamage,
                   (void **)&orig_get_limitDamage);

    g_hooksInstalled = YES;
    NSLog(@"[WHWB] All 3 hooks installed successfully");
}

#pragma mark - 触摸穿透悬浮窗
// 关键: 只拦截按钮/面板上的触摸，其他区域穿透到游戏

@interface WHWBPassthroughView : UIView
@end

@implementation WHWBPassthroughView

// 只有点在子视图上才拦截，其他区域穿透
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 如果 hit 是 self（容器），返回 nil 让触摸穿透
    if (hit == self) return nil;
    return hit;
}

@end

#pragma mark - 悬浮窗按钮 (可拖拽)

@interface WHWBFloatButton : UIButton
@end

@implementation WHWBFloatButton
@end

#pragma mark - 主菜单视图

@interface WHWBMenuView : WHWBPassthroughView
@property (nonatomic, strong) WHWBFloatButton *toggleButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UISwitch *swAttack;
@property (nonatomic, strong) UISwitch *swReady;
@property (nonatomic, strong) UISwitch *swLimitDmg;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, assign) CGPoint dragStart;
@end

@implementation WHWBMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = NO;
    self.panelVisible = NO;

    // ===== 浮动按钮 (小圆点) =====
    self.toggleButton = [WHWBFloatButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 40, 40);
    self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.85];
    self.toggleButton.layer.cornerRadius = 20;
    self.toggleButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toggleButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.toggleButton.layer.shadowOpacity = 0.6;
    self.toggleButton.layer.shadowRadius = 4;
    self.toggleButton.layer.borderWidth = 1.5;
    self.toggleButton.layer.borderColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.8].CGColor;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.toggleButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    // 长按拖拽
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.toggleButton addGestureRecognizer:pan];

    [self addSubview:self.toggleButton];

    // ===== 面板 (默认隐藏) =====
    CGFloat pw = 260, ph = 310;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 46, pw, ph)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.06 green:0.06 blue:0.12 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.6].CGColor;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.clipsToBounds = YES;
    self.panelView.hidden = YES;
    [self addSubview:self.panelView];

    [self setupPanel];

    return self;
}

- (void)setupPanel {
    CGFloat y = 12;
    CGFloat x = 12;
    CGFloat w = 236;

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 24)];
    title.text = @"WHWB Helper v4.0";
    title.textColor = [UIColor colorWithRed:0.35 green:0.7 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 28;

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 14)];
    ver.text = @"v1.10.1 | GameAssembly.dylib";
    ver.textColor = [UIColor colorWithWhite:0.35 alpha:1.0];
    ver.font = [UIFont systemFontOfSize:10];
    ver.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:ver];
    y += 20;

    [self addSeparatorAt:y];
    y += 8;

    // Skill Patches 标题
    UILabel *skLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 16)];
    skLabel.text = @"SKILL PATCHES";
    skLabel.textColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.6 alpha:1.0];
    skLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [self.panelView addSubview:skLabel];
    y += 22;

    y = [self addSwitchAt:y x:x w:w label:@"AttackCanUse -> true" isOn:g_patchSkillAttack action:@selector(toggleAttack:) color:[UIColor colorWithRed:1.0 green:0.3 blue:0.2 alpha:1.0] swPtr:&_swAttack];

    y = [self addSwitchAt:y x:x w:w label:@"IsReady -> true" isOn:g_patchSkillReady action:@selector(toggleReady:) color:[UIColor colorWithRed:1.0 green:0.55 blue:0.1 alpha:1.0] swPtr:&_swReady];

    y += 4;
    [self addSeparatorAt:y];
    y += 8;

    // LimitDamage 标题
    UILabel *ldLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 16)];
    ldLabel.text = @"LIMIT DAMAGE";
    ldLabel.textColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.6 alpha:1.0];
    ldLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [self.panelView addSubview:ldLabel];
    y += 22;

    y = [self addSwitchAt:y x:x w:w label:@"limitDamage = 131072000" isOn:g_patchLimitDamage action:@selector(toggleLimitDmg:) color:[UIColor colorWithRed:0.15 green:0.75 blue:0.35 alpha:1.0] swPtr:&_swLimitDmg];

    y += 8;

    // 状态
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 40)];
    self.statusLabel.text = g_hooksInstalled ? @"Hooks active" : @"Hooks pending...";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.numberOfLines = 0;
    [self.panelView addSubview:self.statusLabel];
}

- (void)addSeparatorAt:(CGFloat)y {
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, y, 236, 0.5)];
    sep.backgroundColor = [UIColor colorWithRed:0.25 green:0.45 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep];
}

- (CGFloat)addSwitchAt:(CGFloat)y x:(CGFloat)x w:(CGFloat)w label:(NSString *)label isOn:(BOOL)isOn action:(SEL)action color:(UIColor *)color swPtr:(UISwitch *WHWBMenuView::* *)swPtr {
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    sw.on = isOn;
    sw.onTintColor = color;
    sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:sw];

    // 存储引用
    if (swPtr == &_swAttack) self.swAttack = sw;
    else if (swPtr == &_swReady) self.swReady = sw;
    else if (swPtr == &_swLimitDmg) self.swLimitDmg = sw;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x + 46, y + 5, w - 46, 20)];
    lbl.text = label;
    lbl.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:lbl];

    return y + 34;
}

#pragma mark - 面板开关

- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panelView.hidden = !self.panelVisible;

    if (self.panelVisible) {
        // 打开时按钮变色
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1.0] colorWithAlphaComponent:0.9];
        [self.toggleButton setTitle:@"X" forState:UIControlStateNormal];
    } else {
        self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.85];
        [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    }
}

#pragma mark - 拖拽

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    CGPoint center = self.center;
    center.x += translation.x;
    center.y += translation.y;

    // 限制在屏幕内
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    center.x = MAX(20, MIN(screenSize.width - 20, center.x));
    center.y = MAX(30, MIN(screenSize.height - 30, center.y));

    self.center = center;
    [gesture setTranslation:CGPointZero inView:self.superview];
}

#pragma mark - 开关回调

- (void)toggleAttack:(UISwitch *)sender {
    g_patchSkillAttack = sender.isOn;
    [self updateStatus];
}

- (void)toggleReady:(UISwitch *)sender {
    g_patchSkillReady = sender.isOn;
    [self updateStatus];
}

- (void)toggleLimitDmg:(UISwitch *)sender {
    g_patchLimitDamage = sender.isOn;
    [self updateStatus];
}

- (void)updateStatus {
    NSMutableArray *on = [NSMutableArray array];
    if (g_patchSkillAttack) [on addObject:@"Atk"];
    if (g_patchSkillReady) [on addObject:@"Ready"];
    if (g_patchLimitDamage) [on addObject:@"Dmg"];
    if (on.count > 0) {
        self.statusLabel.text = [NSString stringWithFormat:@"Active: %@", [on componentsJoinedByString:@", "]];
        self.statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
    } else {
        self.statusLabel.text = @"All OFF - original behavior";
        self.statusLabel.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    }
}

@end

#pragma mark - 显示悬浮窗

static WHWBMenuView *g_menuView = nil;

static void showMenu() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_menuView) return;

        UIWindow *keyWindow = nil;
        // iOS 13+ UIScene
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        if (!keyWindow) return;

        // 创建一个覆盖全屏的穿透容器
        CGRect screenBounds = [UIScreen mainScreen].bounds;
        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 140, 270, 360)];
        g_menuView.alpha = 0;
        [keyWindow addSubview:g_menuView];

        [UIView animateWithDuration:0.3 animations:^{
            g_menuView.alpha = 1.0;
        }];
    });
}

#pragma mark - 入口

__attribute__((constructor))
static void whwb_init() {
    NSLog(@"[WHWB] ====================================");
    NSLog(@"[WHWB] WHWB Helper v4.0 loaded");
    NSLog(@"[WHWB] Target: com.jyjh.whwb v1.10.1");
    NSLog(@"[WHWB] ====================================");

    // 1. 安装所有 MSHookFunction hooks
    installHooks();

    // 2. 默认开启
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;
    g_patchLimitDamage = YES;

    // 3. 延迟显示UI (等游戏界面加载完)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();
    });

    NSLog(@"[WHWB] Init complete - hooks: %@", g_hooksInstalled ? @"OK" : @"FAILED");
}
