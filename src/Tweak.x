#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak - iOS IL2CPP Game Hack
//  Target: FrameSync based game
//  Platform: iOS arm64e, Dopamine rootless
//  Hook: CydiaSubstrate (MSHookFunction)
// ============================================================

#pragma mark - 偏移量 (从 dump.cs 提取)

// CheckSkillAttackCanUse 偏移 0x2a9218
// CheckSkillIsReady 偏移 0x2a9b08
static uintptr_t OFFSET_CHECK_SKILL_ATTACK = 0x2a9218;
static uintptr_t OFFSET_CHECK_SKILL_READY = 0x2a9b08;

#pragma mark - 全局状态

static BOOL g_patchSkillAttack = NO;
static BOOL g_patchSkillReady = NO;

#pragma mark - Hook 函数

static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *characterField, void *states);
static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *characterField, void *states);

static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillAttack) {
        return true;
    }
    return orig_CheckSkillAttackCanUse(frame, stateType, characterField, states);
}

static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) {
        return true;
    }
    return orig_CheckSkillIsReady(frame, stateType, characterField, states);
}

#pragma mark - 获取基址

static uintptr_t getFrameSyncBase() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FrameSync")) {
            uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[WHWB] FrameSync base: 0x%lx", base);
            return base;
        }
    }
    // 主程序
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    NSLog(@"[WHWB] Using main binary base: 0x%lx", base);
    return base;
}

#pragma mark - 安装 Hooks

static void installHooks() {
    uintptr_t base = getFrameSyncBase();
    if (base == 0) {
        NSLog(@"[WHWB] ERROR: base address is 0");
        return;
    }

    void *addrAttack = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    NSLog(@"[WHWB] Hooking CheckSkillAttackCanUse at %p", addrAttack);
    MSHookFunction(addrAttack,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);

    void *addrReady = (void *)(base + OFFSET_CHECK_SKILL_READY);
    NSLog(@"[WHWB] Hooking CheckSkillIsReady at %p", addrReady);
    MSHookFunction(addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);

    NSLog(@"[WHWB] Hooks installed");
}

#pragma mark - UI 悬浮窗

static BOOL g_menuVisible = YES;

@interface WHWBMenuView : UIView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *panelView;
@end

@implementation WHWBMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = NO;

    // 小圆点按钮
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 40, 40);
    self.toggleButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
    self.toggleButton.layer.cornerRadius = 20;
    self.toggleButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.toggleButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.toggleButton.layer.shadowOpacity = 0.4;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.toggleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggleButton];

    // 主面板
    CGFloat pw = 260, ph = 280;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 45, pw, ph)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.6].CGColor;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.clipsToBounds = YES;
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
    title.text = @"WHWB Helper";
    title.textColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 34;

    // 分割线
    UIView *sep = [self makeSeparatorAt:y];
    [self.panelView addSubview:sep];
    y += 8;

    // Skill Patches 标签
    UILabel *skLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 18)];
    skLabel.text = @"Skill Patches";
    skLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    skLabel.font = [UIFont systemFontOfSize:13];
    [self.panelView addSubview:skLabel];
    y += 22;

    // CheckSkillAttackCanUse
    y = [self addSwitchAt:y x:x label:@"AttackCanUse -> true" isOn:g_patchSkillAttack action:@selector(toggleAttack:) color:[UIColor colorWithRed:1.0 green:0.4 blue:0.2 alpha:1.0]];

    // CheckSkillIsReady
    y = [self addSwitchAt:y x:x label:@"IsReady -> true" isOn:g_patchSkillReady action:@selector(toggleReady:) color:[UIColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1.0]];

    y += 4;
    UIView *sep2 = [self makeSeparatorAt:y];
    [self.panelView addSubview:sep2];
    y += 8;

    // 说明
    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 40)];
    note.text = @"These hooks make all skills\nalways usable in battle.";
    note.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    note.font = [UIFont systemFontOfSize:11];
    note.numberOfLines = 0;
    [self.panelView addSubview:note];
}

- (UIView *)makeSeparatorAt:(CGFloat)y {
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, y, 236, 1)];
    sep.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.3];
    return sep;
}

- (CGFloat)addSwitchAt:(CGFloat)y x:(CGFloat)x label:(NSString *)label isOn:(BOOL)isOn action:(SEL)action color:(UIColor *)color {
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    sw.on = isOn;
    sw.onTintColor = color;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:sw];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 5, 160, 20)];
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
    NSLog(@"[WHWB] Patch SkillAttack: %@", g_patchSkillAttack ? @"ON" : @"OFF");
}

- (void)toggleReady:(UISwitch *)sender {
    g_patchSkillReady = sender.isOn;
    NSLog(@"[WHWB] Patch SkillReady: %@", g_patchSkillReady ? @"ON" : @"OFF");
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

        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 270, 340)];
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
    NSLog(@"[WHWB] === WHWB Helper v1.0 loaded ===");

    // 安装 hooks
    installHooks();

    // 默认开启
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;

    // 延迟显示UI
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();
    });

    NSLog(@"[WHWB] Init complete");
}
