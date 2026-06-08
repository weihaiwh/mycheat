#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

// ============================================================
//  WHWB Tweak v7.0 - 无 CydiaSubstrate 依赖版本
//  Target: com.jyjh.whwb v1.10.1 (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//
//  v7.0 核心变更:
//  - 不链接 CydiaSubstrate! 用 dlsym 运行时加载 MSHookFunction
//  - 添加 mprotect+inline patch 作为 fallback
//  - 这样 dylib 可以被 Substrate 和 TrollFools 两种方式注入
//  - 保留文件日志 + 悬浮窗 UI
// ============================================================

#pragma mark - 文件日志

static NSString *LOG_PATH = @"/var/mobile/Documents/whwb.log";

static void fileLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void fileLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[WHWB] %@", msg);

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
        [line writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

#pragma mark - 运行时加载 MSHookFunction (不链接 CydiaSubstrate!)

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
static MSHookFunction_t MSHookFunction_ptr = NULL;

static void loadSubstrateRuntime() {
    // 尝试多种路径加载 CydiaSubstrate/ElleKit
    NSArray *paths = @[
        @"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        @"/usr/lib/libsubstrate.dylib",
        @"/var/jb/usr/lib/libsubstrate.dylib",
        @"/var/jb/usr/lib/libellekit.dylib"
    ];

    for (NSString *path in paths) {
        void *handle = dlopen([path UTF8String], RTLD_LAZY | RTLD_NOLOAD);
        if (handle) {
            fileLog(@"Substrate already loaded: %@", path);
            MSHookFunction_ptr = (MSHookFunction_t)dlsym(handle, "MSHookFunction");
            if (MSHookFunction_ptr) {
                fileLog(@"MSHookFunction found via dlsym: %p", MSHookFunction_ptr);
                return;
            }
        }
    }

    // 如果还没加载, 尝试主动加载
    for (NSString *path in paths) {
        void *handle = dlopen([path UTF8String], RTLD_LAZY);
        if (handle) {
            MSHookFunction_ptr = (MSHookFunction_t)dlsym(handle, "MSHookFunction");
            if (MSHookFunction_ptr) {
                fileLog(@"MSHookFunction loaded from: %@", path);
                return;
            }
        }
    }

    fileLog(@"WARNING: MSHookFunction NOT found, will use inline patching");
}

#pragma mark - Inline ARM64 Memory Patching (fallback)

// 保存原始字节用于恢复
static uint32_t g_origBytes_Attack[2] = {0};
static uint32_t g_origBytes_Ready[2] = {0};
static uint32_t g_origBytes_LimitDmg[2] = {0};
static void *g_patchAddr_Attack = NULL;
static void *g_patchAddr_Ready = NULL;
static void *g_patchAddr_LimitDmg = NULL;

static BOOL patchMemory(void *addr, const void *patch, size_t patchSize) {
    if (!addr) return NO;

    uintptr_t page = (uintptr_t)addr & ~(getpagesize() - 1);
    size_t offset = (uintptr_t)addr - page;
    size_t len = (offset + patchSize + getpagesize() - 1) & ~(getpagesize() - 1);

    // 修改内存保护为 RWX
    if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        fileLog(@"mprotect RWX FAILED for %p: %s", addr, strerror(errno));
        // 尝试 vm_protect 作为 fallback
        // Dopamine 越狱应该允许 mprotect
        return NO;
    }

    // 写入补丁
    memcpy(addr, patch, patchSize);

    // 刷新指令缓存
    sys_icache_invalidate(addr, patchSize);

    // 恢复为只读+可执行
    mprotect((void *)page, len, PROT_READ | PROT_EXEC);

    return YES;
}

// ARM64: MOV W0, #imm16; RET
// MOV W0, #imm16 = 0x52800000 | (imm16 << 5)
// RET on ARM64e = RETAA = 0xD65F0FFF (兼容 ARM64 和 ARM64e)
static uint32_t makeMovW0(uint16_t imm16) {
    return 0x52800000 | ((uint32_t)imm16 << 5);
}

// 生成 "return true" 补丁: MOV W0, #1; RETAA
static void makePatchReturnTrue(uint32_t *out) {
    out[0] = makeMovW0(1);  // MOV W0, #1
    out[1] = 0xD65F0FFF;    // RETAA (ARM64e PAC 兼容)
}

// 生成 "return TARGET_LIMIT_DAMAGE" 补丁
// 注意: TARGET_LIMIT_DAMAGE = 131072000 = 0x7D00000
// 这个值超过 16 位, 需要多条指令
// MOVZ W0, #0; MOVK W0, #0x7D0, LSL #16; RETAA
// 等等... 但实际上 get_limitDamage 返回 Int32
// 131072000 = 0x07D00000
// 用 MOVZ + MOVK:
//   MOVZ W0, #0x0000          = 0x52800000
//   MOVK W0, #0x07D0, LSL #16 = 0x72A00FA0
//   RETAA                      = 0xD65F0FFF
static void makePatchReturnLimitDamage(uint32_t *out) {
    out[0] = 0x52800000;    // MOVZ W0, #0
    out[1] = 0x72A00FA0;    // MOVK W0, #0x07D0, LSL #16
    out[2] = 0xD65F0FFF;    // RETAA
}

#pragma mark - Hook 函数 (用于 MSHookFunction 方式)

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
            return base;
        }
    }
    return 0;
}

#pragma mark - 安装 Hooks (两种方式)

static BOOL g_useInlinePatch = NO;

static void installHooks() {
    if (g_hooksInstalled) return;

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        fileLog(@"GameAssembly not loaded yet");
        return;
    }
    fileLog(@"GameAssembly base: 0x%lx", (unsigned long)base);

    void *addrAttack  = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    void *addrReady   = (void *)(base + OFFSET_CHECK_SKILL_READY);
    void *addrLimitDmg = (void *)(base + OFFSET_GET_LIMIT_DAMAGE);

    fileLog(@"Hook addresses: Attack=%p Ready=%p LimitDmg=%p", addrAttack, addrReady, addrLimitDmg);

    // 尝试 MSHookFunction 方式
    if (MSHookFunction_ptr) {
        fileLog(@"Using MSHookFunction method...");
        MSHookFunction_ptr(addrAttack,  (void *)hook_CheckSkillAttackCanUse, (void **)&orig_CheckSkillAttackCanUse);
        MSHookFunction_ptr(addrReady,   (void *)hook_CheckSkillIsReady,      (void **)&orig_CheckSkillIsReady);
        MSHookFunction_ptr(addrLimitDmg,(void *)hook_get_limitDamage,        (void **)&orig_get_limitDamage);
        fileLog(@"MSHookFunction hooks installed OK!");
    } else {
        // Inline patching fallback
        fileLog(@"Using inline memory patching method...");
        g_useInlinePatch = YES;

        // 保存原始字节
        memcpy(g_origBytes_Attack, addrAttack, sizeof(g_origBytes_Attack));
        memcpy(g_origBytes_Ready, addrReady, sizeof(g_origBytes_Ready));
        memcpy(g_origBytes_LimitDmg, addrLimitDmg, sizeof(g_origBytes_LimitDmg));
        g_patchAddr_Attack = addrAttack;
        g_patchAddr_Ready = addrReady;
        g_patchAddr_LimitDmg = addrLimitDmg;

        // 应用补丁: 所有功能默认开启
        uint32_t patchTrue[2];
        makePatchReturnTrue(patchTrue);
        uint32_t patchLimitDmg[3];
        makePatchReturnLimitDamage(patchLimitDmg);

        BOOL r1 = patchMemory(addrAttack, patchTrue, sizeof(patchTrue));
        BOOL r2 = patchMemory(addrReady, patchTrue, sizeof(patchTrue));
        BOOL r3 = patchMemory(addrLimitDmg, patchLimitDmg, sizeof(patchLimitDmg));

        fileLog(@"Inline patch results: Attack=%d Ready=%d LimitDmg=%d", r1, r2, r3);
    }

    g_hooksInstalled = YES;
    g_patchSkillAttack = YES;
    g_patchSkillReady  = YES;
    g_patchLimitDamage = YES;
    fileLog(@"All hooks installed! Method: %s", MSHookFunction_ptr ? "MSHookFunction" : "InlinePatch");
}

// Toggle inline patches on/off
static void applyInlinePatch(BOOL enable, void *addr, uint32_t *origBytes, size_t origSize) {
    if (!addr) return;
    if (enable) {
        // 需要重新应用补丁
        // 根据 addr 决定用哪个补丁
        if (addr == g_patchAddr_Attack || addr == g_patchAddr_Ready) {
            uint32_t patchTrue[2];
            makePatchReturnTrue(patchTrue);
            patchMemory(addr, patchTrue, sizeof(patchTrue));
        } else if (addr == g_patchAddr_LimitDmg) {
            uint32_t patchLimitDmg[3];
            makePatchReturnLimitDamage(patchLimitDmg);
            patchMemory(addr, patchLimitDmg, sizeof(patchLimitDmg));
        }
    } else {
        // 恢复原始字节
        patchMemory(addr, origBytes, origSize);
    }
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

    // ---- 浮动按钮 ----
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

    // ---- 面板 ----
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
    title.text = @"WHWB Helper v7.0";
    title.textColor = [UIColor colorWithRed:0.35 green:0.7 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 26;

    UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 13)];
    ver.text = @"No-Substrate Edition";
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

- (void)toggleAttack:(UISwitch *)s {
    g_patchSkillAttack = s.isOn;
    if (g_useInlinePatch) {
        applyInlinePatch(s.isOn, g_patchAddr_Attack, g_origBytes_Attack, sizeof(g_origBytes_Attack));
    }
    [self refreshStatus];
}

- (void)toggleReady:(UISwitch *)s {
    g_patchSkillReady = s.isOn;
    if (g_useInlinePatch) {
        applyInlinePatch(s.isOn, g_patchAddr_Ready, g_origBytes_Ready, sizeof(g_origBytes_Ready));
    }
    [self refreshStatus];
}

- (void)toggleLimitDmg:(UISwitch *)s {
    g_patchLimitDamage = s.isOn;
    if (g_useInlinePatch) {
        applyInlinePatch(s.isOn, g_patchAddr_LimitDmg, g_origBytes_LimitDmg, sizeof(g_origBytes_LimitDmg));
    }
    [self refreshStatus];
}

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
    NSString *method = g_useInlinePatch ? @"[Inline]" : @"[Substrate]";
    if (a.count) {
        self.statusLabel.text = [NSString stringWithFormat:@"%@ Active: %@", method, [a componentsJoinedByString:@", "]];
        self.statusLabel.textColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0];
    } else {
        self.statusLabel.text = [NSString stringWithFormat:@"%@ All OFF", method];
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

#pragma mark - 诊断

static void dumpLoadedImages() {
    fileLog(@"=== Loaded images (%u) ===", _dyld_image_count());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "GameAssembly") || strstr(name, "WHWB") || strstr(name, "whwb") || strstr(name, "jyjh") || strstr(name, "Substrate") || strstr(name, "ellekit") || strstr(name, "TweakLoader"))) {
            fileLog(@"  [%u] %s base=0x%lx", i, name, (unsigned long)_dyld_get_image_header(i));
        }
    }
}

static void dumpAppState() {
    UIApplication *app = [UIApplication sharedApplication];
    fileLog(@"AppState: app=%p state=%ld", app, (long)app.applicationState);
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in app.connectedScenes) {
            fileLog(@"  scene: state=%ld windows=%lu",
                    (long)scene.activationState,
                    (unsigned long)scene.windows.count);
        }
    }
    fileLog(@"  windows=%lu keyWindow=%p", (unsigned long)app.windows.count, app.keyWindow);
}

#pragma mark - 创建悬浮窗

static void showMenu() {
    if (g_menuView) {
        fileLog(@"showMenu: already exists");
        return;
    }

    fileLog(@"showMenu: creating overlay window...");

    UIWindow *overlayWindow = nil;

    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                overlayWindow = [[WHWBPassthroughWindow alloc] initWithWindowScene:scene];
                fileLog(@"  created window WITH scene: %p", overlayWindow);
                break;
            }
        }
    }

    if (!overlayWindow) {
        overlayWindow = [[WHWBPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        fileLog(@"  created window WITHOUT scene (fallback): %p", overlayWindow);
    }

    if (!overlayWindow) {
        fileLog(@"FATAL: could not create window!");
        return;
    }

    overlayWindow.frame = [UIScreen mainScreen].bounds;
    overlayWindow.backgroundColor = [UIColor clearColor];
    overlayWindow.windowLevel = UIWindowLevelNormal + 200;
    overlayWindow.clipsToBounds = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    WHWBPassthroughView *containerView = [[WHWBPassthroughView alloc] initWithFrame:overlayWindow.bounds];
    containerView.backgroundColor = [UIColor clearColor];
    containerView.userInteractionEnabled = YES;
    vc.view = containerView;

    g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 260, 340)];
    [containerView addSubview:g_menuView];

    overlayWindow.rootViewController = vc;
    overlayWindow.hidden = NO;

    g_overlayWindow = (WHWBPassthroughWindow *)overlayWindow;

    if (g_hooksInstalled) {
        [g_menuView onHooksInstalled];
    }

    fileLog(@"Overlay window created! level=%.0f ptr=%p", overlayWindow.windowLevel, overlayWindow);
}

#pragma mark - 轮询安装 Hooks

static void tryInstallHooks();

static void tryInstallHooks() {
    if (g_hooksInstalled) return;

    g_hookRetryCount++;
    fileLog(@"tryInstallHooks #%d, images=%u", g_hookRetryCount, _dyld_image_count());

    uintptr_t base = getGameAssemblyBase();
    if (base == 0) {
        if (g_hookRetryCount < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                tryInstallHooks();
            });
        } else {
            fileLog(@"ERROR: GameAssembly not found after 30s");
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
            g_menuView.statusLabel.text = [NSString stringWithFormat:@"Error: %@", e.reason];
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

    dumpAppState();
    dumpLoadedImages();

    // 加载 Substrate 运行时 (dlsym 方式)
    loadSubstrateRuntime();

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
    // 清空旧日志
    [@"=== WHWB v7.0 Log Start ===\n" writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0666)}
                                     ofItemAtPath:LOG_PATH
                                            error:nil];

    fileLog(@"====================================");
    fileLog(@"WHWB Helper v7.0 constructor loaded");
    fileLog(@"No-Substrate Edition!");
    fileLog(@"PID: %d", getpid());
    fileLog(@"====================================");

    // 列出关键 images
    fileLog(@"Images at constructor time: %u", _dyld_image_count());
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "GameAssembly") || strstr(name, "WHWB") || strstr(name, "jyjh") || strstr(name, "Substrate") || strstr(name, "ellekit") || strstr(name, "TweakLoader"))) {
            fileLog(@"  [%u] %s", i, name);
        }
    }

    // 注册通知, 等 app 激活后初始化 UI
    __block id activeObserver = nil;
    activeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
        activeObserver = nil;
        fileLog(@"App became active notification!");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            delayedInit();
        });
    }];

    // 5秒 fallback
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_menuView) {
            fileLog(@"Fallback: 5s timeout!");
            if (activeObserver) {
                [[NSNotificationCenter defaultCenter] removeObserver:activeObserver];
                activeObserver = nil;
            }
            delayedInit();
        }
    });

    fileLog(@"Constructor done, waiting for activation...");
}
