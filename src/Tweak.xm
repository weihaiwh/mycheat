#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v3.0 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//  Hook: CydiaSubstrate (MSHookFunction)
// ============================================================

#pragma mark - 偏移量 (v1.10.1 dump.cs)
// CheckSkillAttackCanUse: 0x30741b8
// CheckSkillIsReady:      0x3074b54
// get_limitDamage:        0x30a2f70
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

#pragma mark - 获取基址

static uintptr_t getBaseAddress() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FrameSync")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return (uintptr_t)_dyld_get_image_header(0);
}

#pragma mark - 安装所有 Hooks

static void installHooks() {
    uintptr_t base = getBaseAddress();
    if (base == 0) {
        NSLog(@"[WHWB] ERROR: base address is 0");
        return;
    }
    NSLog(@"[WHWB] Base address: 0x%lx", base);

    // Hook CheckSkillAttackCanUse
    void *addrAttack = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    MSHookFunction(addrAttack,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);
    NSLog(@"[WHWB] Hooked CheckSkillAttackCanUse at %p", addrAttack);

    // Hook CheckSkillIsReady
    void *addrReady = (void *)(base + OFFSET_CHECK_SKILL_READY);
    MSHookFunction(addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);
    NSLog(@"[WHWB] Hooked CheckSkillIsReady at %p", addrReady);

    // Hook get_limitDamage
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);
    MSHookFunction(addrLimitDmg,
                   (void *)hook_get_limitDamage,
                   (void **)&orig_get_limitDamage);
    NSLog(@"[WHWB] Hooked get_limitDamage at %p", addrLimitDmg);
}

#pragma mark - UI 悬浮窗

static BOOL g_menuVisible = YES;

@interface WHWBMenuView : UIView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation WHWBMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = NO;

    // 浮动按钮
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 44, 44);
    self.toggleButton.backgroundColor = [[UIColor colorWithRed:0.2 green:0.4 blue:1.0 alpha:1.0] colorWithAlphaComponent:0.9];
    self.toggleButton.layer.cornerRadius = 22;
    self.toggleButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toggleButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.toggleButton.layer.shadowOpacity = 0.5;
    self.toggleButton.layer.shadowRadius = 4;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.toggleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggleButton];

    // 主面板
    CGFloat pw = 280, ph = 340;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 50, pw, ph)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.14 alpha:0.96];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.7].CGColor;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.clipsToBounds = YES;
    [self addSubview:self.panelView];

    [self setupPanel];
    return self;
}

- (void)setupPanel {
    CGFloat y = 14;
    CGFloat x = 14;
    CGFloat w = 252;

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 26)];
    title.text = @"WHWB Helper v3.0";
    title.textColor = [UIColor colorWithRed:0.4 green:0.75 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 32;

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 16)];
    ver.text = @"v1.10.1 offsets";
    ver.textColor = [UIColor colorWithWhite:0.4 alpha:1.0];
    ver.font = [UIFont systemFontOfSize:11];
    ver.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:ver];
    y += 22;

    [self addSeparatorAt:y];
    y += 10;

    // Skill Patches
    UILabel *skLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 18)];
    skLabel.text = @"Skill Patches";
    skLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    skLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.panelView addSubview:skLabel];
    y += 24;

    y = [self addSwitchAt:y x:x w:w label:@"AttackCanUse -> true" isOn:g_patchSkillAttack action:@selector(toggleAttack:) color:[UIColor colorWithRed:1.0 green:0.35 blue:0.2 alpha:1.0]];

    y = [self addSwitchAt:y x:x w:w label:@"IsReady -> true" isOn:g_patchSkillReady action:@selector(toggleReady:) color:[UIColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1.0]];

    y += 6;
    [self addSeparatorAt:y];
    y += 10;

    // LimitDamage
    UILabel *ldLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 18)];
    ldLabel.text = @"LimitDamage (hook get_limitDamage)";
    ldLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    ldLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.panelView addSubview:ldLabel];
    y += 24;

    y = [self addSwitchAt:y x:x w:w label:@"LimitDamage = 131072000" isOn:g_patchLimitDamage action:@selector(toggleLimitDmg:) color:[UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0]];

    y += 6;

    // 状态
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 50)];
    self.statusLabel.text = @"Hooks installed. Toggle switches above.";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.numberOfLines = 0;
    [self.panelView addSubview:self.statusLabel];
}

- (void)addSeparatorAt:(CGFloat)y {
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(14, y, 252, 1)];
    sep.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.25];
    [self.panelView addSubview:sep];
}

- (CGFloat)addSwitchAt:(CGFloat)y x:(CGFloat)x w:(CGFloat)w label:(NSString *)label isOn:(BOOL)isOn action:(SEL)action color:(UIColor *)color {
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    sw.on = isOn;
    sw.onTintColor = color;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:sw];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 5, w - 60, 20)];
    lbl.text = label;
    lbl.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:13];
    [self.panelView addSubview:lbl];

    return y + 38;
}

- (void)toggleMenu {
    g_menuVisible = !g_menuVisible;
    self.panelView.hidden = !g_menuVisible;
}

- (void)toggleAttack:(UISwitch *)sender {
    g_patchSkillAttack = sender.isOn;
    self.statusLabel.text = [NSString stringWithFormat:@"AttackCanUse: %@", g_patchSkillAttack ? @"ALWAYS TRUE" : @"ORIGINAL"];
    NSLog(@"[WHWB] Patch SkillAttack: %@", g_patchSkillAttack ? @"ON" : @"OFF");
}

- (void)toggleReady:(UISwitch *)sender {
    g_patchSkillReady = sender.isOn;
    self.statusLabel.text = [NSString stringWithFormat:@"IsReady: %@", g_patchSkillReady ? @"ALWAYS TRUE" : @"ORIGINAL"];
    NSLog(@"[WHWB] Patch SkillReady: %@", g_patchSkillReady ? @"ON" : @"OFF");
}

- (void)toggleLimitDmg:(UISwitch *)sender {
    g_patchLimitDamage = sender.isOn;
    self.statusLabel.text = [NSString stringWithFormat:@"limitDamage: %@", g_patchLimitDamage ? @"131072000" : @"ORIGINAL"];
    NSLog(@"[WHWB] Patch LimitDamage: %@", g_patchLimitDamage ? @"ON" : @"OFF");
}

@end

#pragma mark - 显示悬浮窗

static WHWBMenuView *g_menuView = nil;

static void showMenu() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_menuView) return;

        UIWindow *keyWindow = nil;
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

        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 120, 290, 400)];
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
    NSLog(@"[WHWB] WHWB Helper v3.0 loaded");
    NSLog(@"[WHWB] Target: com.jyjh.whwb v1.10.1");
    NSLog(@"[WHWB] ====================================");

    // 1. 安装所有 MSHookFunction hooks
    installHooks();

    // 2. 默认开启
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;
    g_patchLimitDamage = YES;

    // 3. 延迟显示UI
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();
    });

    NSLog(@"[WHWB] Init complete - all hooks active");
}
