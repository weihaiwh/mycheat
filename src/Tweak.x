#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak - 万魂武榜 iOS 游戏辅助插件
//  目标: FrameSync.RuntimeConfig.limitDamage + 技能无限释放
//  平台: iOS arm64e, Dopamine rootless, TrollStore 注入
//  Hook 框架: CydiaSubstrate (MSHookFunction)
// ============================================================

#pragma mark - IL2CPP 基础类型

// IL2CPP String
typedef struct Il2CppString_ {
    void *klass;
    void *monitor;
    int length;
    uint16_t chars[0];
} Il2CppString;

// IL2CPP Array
template<typename T>
struct Il2CppArray {
    void *klass;
    void *monitor;
    void *bounds;
    int max_length;
    T items[0];
};

// Deterministic.FP (定点数, 8字节 Int64)
// RawValue / 65536 = AsLong (实际值)
typedef struct FP_ {
    int64_t rawValue;
} FP;

// FPVector2
typedef struct FPVector2_ {
    FP x;
    FP y;
} FPVector2;

#pragma mark - IL2CPP API 函数指针

static void *(*il2cpp_class_from_name)(void *image, const char *ns, const char *name);
static void *(*il2cpp_method_from_name)(void *klass, const char *name, int paramCount);
static void *(*il2cpp_class_get_methods)(void *klass, void **iter);
static void *(*il2cpp_class_get_method_from_name)(void *klass, const char *name, int paramCount);
static void *(*il2cpp_resolve_icall)(const char *name);
static void *(*il2cpp_runtime_class_init)(void *klass);
static void *(*il2cpp_object_new)(void *klass);
static void *(*il2cpp_field_static_get_value)(void *field, void *value);
static void *(*il2cpp_field_static_set_value)(void *field, void *value);
static void *(*il2cpp_field_get_value)(void *obj, void *field, void *value);
static void *(*il2cpp_field_set_value)(void *obj, void *field, void *value);
static void *(*il2cpp_class_get_field_from_name)(void *klass, const char *name);
static void **(*il2cpp_domain_get)(void);
static void *(*il2cpp_domain_get_assemblies)(void *domain, size_t *size);
static void *(*il2cpp_assembly_get_image)(void *assembly);
static const char *(*il2cpp_image_get_name)(void *image);
static void *(*il2cpp_class_from_il2cpp_type)(void *type);

#pragma mark - 游戏偏移量 (从 dump.cs 提取)

// FrameSync.RuntimeConfig
// limitDamage 是 Deterministic.FP 类型, 偏移 0x40
static const int OFFSET_LIMIT_DAMAGE = 0x40;

// FrameSync.CharacterSkillInfo
// Skill1~Skill6 每个 SkillStateData 偏移
// Skill1=0x40, Skill2=0x50, Skill3=0x60, Skill4=0x70, Skill5=0x80, Skill6=0x90, SkillSprint=0xa0
static const int OFFSET_SKILLINFO_SKILLS[] = {0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xa0};

// FrameSync.SkillStateData
// CoolDown (FP) 偏移 0x18
// Count (Int16) 偏移 0x14
// CountMax (Int16) 偏移 0x16
static const int OFFSET_COOLDOWN = 0x18;
static const int OFFSET_COUNT = 0x14;
static const int OFFSET_COUNT_MAX = 0x16;

// FrameSync.CharacterFiled
// SkillInfo 偏移 0x340
static const int OFFSET_SKILLINFO = 0x340;

// CheckSkillAttackCanUse 偏移 0x2a9218 (相对于基址)
// CheckSkillIsReady 偏移 0x2a9b08
static uintptr_t OFFSET_CHECK_SKILL_ATTACK = 0x2a9218;
static uintptr_t OFFSET_CHECK_SKILL_READY = 0x2a9b08;

#pragma mark - 全局状态

static BOOL g_autoLimitDamage = NO;
static BOOL g_autoNoCD = NO;
static BOOL g_patchSkillAttack = NO;
static BOOL g_patchSkillReady = NO;
static int64_t g_targetRawValue = 131072000; // AsLong=2000

static void *g_runtimeConfigClass = NULL;
static void *g_characterFiledClass = NULL;

#pragma mark - Hook 函数

// CheckSkillAttackCanUse 原函数
static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *characterField, void *states);
static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *characterField, void *states);

// Hook: CheckSkillAttackCanUse -> always true
static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillAttack) {
        return true;
    }
    return orig_CheckSkillAttackCanUse(frame, stateType, characterField, states);
}

// Hook: CheckSkillIsReady -> always true
static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) {
        return true;
    }
    return orig_CheckSkillIsReady(frame, stateType, characterField, states);
}

#pragma mark - IL2CPP 初始化

static void initIL2CPP() {
    void *handle = dlopen(NULL, RTLD_LAZY);
    if (!handle) return;

    #define LOAD_SYM(name) name = (typeof(name))dlsym(handle, #name)

    LOAD_SYM(il2cpp_class_from_name);
    LOAD_SYM(il2cpp_class_get_method_from_name);
    LOAD_SYM(il2cpp_domain_get);
    LOAD_SYM(il2cpp_domain_get_assemblies);
    LOAD_SYM(il2cpp_assembly_get_image);
    LOAD_SYM(il2cpp_image_get_name);
    LOAD_SYM(il2cpp_object_new);
    LOAD_SYM(il2cpp_runtime_class_init);
    LOAD_SYM(il2cpp_class_get_field_from_name);
    LOAD_SYM(il2cpp_field_static_get_value);
    LOAD_SYM(il2cpp_field_static_set_value);
    LOAD_SYM(il2cpp_field_get_value);
    LOAD_SYM(il2cpp_field_set_value);

    #undef LOAD_SYM

    NSLog(@"[WHWB] IL2CPP symbols loaded");
}

// 查找 FrameSync.code.dll 的 image
static void *findFrameSyncImage() {
    if (!il2cpp_domain_get || !il2cpp_domain_get_assemblies) return NULL;

    void *domain = il2cpp_domain_get();
    if (!domain) return NULL;

    size_t size = 0;
    void **assemblies = (void **)il2cpp_domain_get_assemblies(domain, &size);
    if (!assemblies) return NULL;

    for (size_t i = 0; i < size; i++) {
        void *image = il2cpp_assembly_get_image(assemblies[i]);
        if (!image) continue;
        const char *name = il2cpp_image_get_name(image);
        if (name && strstr(name, "FrameSync.code")) {
            NSLog(@"[WHWB] Found image: %s", name);
            return image;
        }
    }
    return NULL;
}

// 查找 IL2CPP 类
static void *findClass(const char *className) {
    void *image = findFrameSyncImage();
    if (!image || !il2cpp_class_from_name) return NULL;

    // 尝试 namespace=FrameSync, name=className
    void *cls = il2cpp_class_from_name(image, "FrameSync", className);
    if (cls) {
        NSLog(@"[WHWB] Found class FrameSync.%s at %p", className, cls);
        return cls;
    }

    // 尝试 namespace="", name=完整名
    char fullName[256];
    snprintf(fullName, sizeof(fullName), "FrameSync.%s", className);
    // 再试无 namespace
    cls = il2cpp_class_from_name(image, "", fullName);
    if (cls) {
        NSLog(@"[WHWB] Found class %s at %p", fullName, cls);
        return cls;
    }

    NSLog(@"[WHWB] Class %s not found", className);
    return NULL;
}

#pragma mark - 游戏功能

// 设置 limitDamage
static void setLimitDamage() {
    if (!g_runtimeConfigClass) {
        g_runtimeConfigClass = findClass("RuntimeConfig");
    }
    if (!g_runtimeConfigClass) return;

    // 获取 limitDamage 字段
    if (!il2cpp_class_get_field_from_name) return;
    void *field = il2cpp_class_get_field_from_name(g_runtimeConfigClass, "limitDamage");
    if (!field) {
        NSLog(@"[WHWB] limitDamage field not found");
        return;
    }

    // RuntimeConfig 可能有静态实例，或者需要从对象获取
    // 先尝试通过静态字段获取
    // 实际游戏中 RuntimeConfig 是通过 Frame 获取的
    // 这里我们需要找到运行时的对象

    NSLog(@"[WHWB] limitDamage field found, setting RawValue=%lld", g_targetRawValue);
}

// 通过内存偏移直接修改技能CD
static void clearSkillCD(void *characterFiledPtr) {
    if (!characterFiledPtr) return;

    // SkillInfo 在 CharacterFiled 偏移 0x340
    uint8_t *cfBase = (uint8_t *)characterFiledPtr;
    uint8_t *skillInfo = cfBase + OFFSET_SKILLINFO;

    for (int i = 0; i < 7; i++) {
        uint8_t *skill = skillInfo + OFFSET_SKILLINFO_SKILLS[i];

        // CoolDown (FP) = 0, 偏移 0x18
        int64_t *coolDown = (int64_t *)(skill + OFFSET_COOLDOWN);
        *coolDown = 0;

        // Count = CountMax, 偏移 0x14 和 0x16
        int16_t *count = (int16_t *)(skill + OFFSET_COUNT);
        int16_t *countMax = (int16_t *)(skill + OFFSET_COUNT_MAX);
        if (*countMax > 0) {
            *count = *countMax;
        }
    }
}

// 直接设置 limitDamage RawValue (通过内存偏移)
static void setLimitDamageByOffset(void *runtimeConfigPtr) {
    if (!runtimeConfigPtr) return;

    // limitDamage 是 FP 类型, 偏移 0x40
    // FP.rawValue 是 int64_t, 就是 FP 结构体的第一个字段
    uint8_t *base = (uint8_t *)runtimeConfigPtr;
    int64_t *rawValue = (int64_t *)(base + OFFSET_LIMIT_DAMAGE);

    *rawValue = g_targetRawValue;

    NSLog(@"[WHWB] Set limitDamage RawValue=%lld at %p+0x%x", g_targetRawValue, runtimeConfigPtr, OFFSET_LIMIT_DAMAGE);
}

#pragma mark - 获取游戏基址

static uintptr_t getBaseAddress() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FrameSync.code")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    // 如果没找到 FrameSync.code.dll, 返回主程序基址
    return (uintptr_t)_dyld_get_image_header(0);
}

// 获取 FrameSync.code.dll 基址
static uintptr_t getFrameSyncBase() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "FrameSync.code")) {
            uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[WHWB] FrameSync.code base: 0x%lx", base);
            return base;
        }
    }
    // 可能是主程序
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "whwb")) {
            uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[WHWB] App base: 0x%lx", base);
            return base;
        }
    }
    return 0;
}

#pragma mark - Hook 安装

static void installHooks() {
    uintptr_t base = getFrameSyncBase();
    if (base == 0) {
        NSLog(@"[WHWB] FrameSync base not found, trying main binary");
        base = (uintptr_t)_dyld_get_image_header(0);
    }

    // Hook CheckSkillAttackCanUse
    uintptr_t addrAttack = base + OFFSET_CHECK_SKILL_ATTACK;
    NSLog(@"[WHWB] Hooking CheckSkillAttackCanUse at 0x%lx", addrAttack);
    MSHookFunction((void *)addrAttack,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);

    // Hook CheckSkillIsReady
    uintptr_t addrReady = base + OFFSET_CHECK_SKILL_READY;
    NSLog(@"[WHWB] Hooking CheckSkillIsReady at 0x%lx", addrReady);
    MSHookFunction((void *)addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);

    NSLog(@"[WHWB] Hooks installed successfully");
}

#pragma mark - UI (基于 UIKit 的悬浮窗)

static UIViewController *g_menuVC = nil;
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

    // 折叠按钮 (小圆点)
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(0, 0, 40, 40);
    self.toggleButton.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.8];
    self.toggleButton.layer.cornerRadius = 20;
    [self.toggleButton setTitle:@"W" forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.toggleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.toggleButton];

    // 主面板
    CGFloat pw = 260, ph = 320;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(0, 45, pw, ph)];
    self.panelView.backgroundColor = [[UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.92];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.6].CGColor;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.clipsToBounds = YES;
    [self addSubview:self.panelView];

    [self setupPanelContent];

    return self;
}

- (void)setupPanelContent {
    CGFloat y = 12;
    CGFloat w = 240;
    CGFloat x = 10;

    // 标题
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 24)];
    title.text = @"⚔️ WHWB Helper";
    title.textColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 32;

    // 分割线
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 1)];
    sep1.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep1];
    y += 10;

    // limitDamage 标签
    UILabel *ldLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 20)];
    ldLabel.text = @"🗡 limitDamage (RawValue=131072000)";
    ldLabel.textColor = [UIColor whiteColor];
    ldLabel.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:ldLabel];
    y += 24;

    // Auto limitDamage 开关
    UISwitch *ldSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    ldSwitch.on = g_autoLimitDamage;
    ldSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0];
    [ldSwitch addTarget:self action:@selector(toggleLimitDamage:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:ldSwitch];

    UILabel *ldSw = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 4, 120, 20)];
    ldSw.text = @"Auto Set";
    ldSw.textColor = [UIColor lightTextColor];
    ldSw.font = [UIFont systemFontOfSize:14];
    [self.panelView addSubview:ldSw];
    y += 40;

    // 分割线
    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 1)];
    sep2.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep2];
    y += 10;

    // Skill Patch 标签
    UILabel *skLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 20)];
    skLabel.text = @"⚡ Skill Patches";
    skLabel.textColor = [UIColor whiteColor];
    skLabel.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:skLabel];
    y += 24;

    // CheckSkillAttackCanUse
    UISwitch *atkSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    atkSwitch.on = g_patchSkillAttack;
    atkSwitch.onTintColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.2 alpha:1.0];
    [atkSwitch addTarget:self action:@selector(toggleSkillAttack:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:atkSwitch];

    UILabel *atkSw = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 4, 160, 20)];
    atkSw.text = @"AttackCanUse → true";
    atkSw.textColor = [UIColor lightTextColor];
    atkSw.font = [UIFont systemFontOfSize:13];
    [self.panelView addSubview:atkSw];
    y += 36;

    // CheckSkillIsReady
    UISwitch *rdySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    rdySwitch.on = g_patchSkillReady;
    rdySwitch.onTintColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1.0];
    [rdySwitch addTarget:self action:@selector(toggleSkillReady:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:rdySwitch];

    UILabel *rdySw = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 4, 160, 20)];
    rdySw.text = @"IsReady → true";
    rdySw.textColor = [UIColor lightTextColor];
    rdySw.font = [UIFont systemFontOfSize:13];
    [self.panelView addSubview:rdySw];
    y += 40;

    // 分割线
    UIView *sep3 = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 1)];
    sep3.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:1.0 alpha:0.3];
    [self.panelView addSubview:sep3];
    y += 10;

    // CD 清除
    UILabel *cdLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 20)];
    cdLabel.text = @"🔄 No CD + Full Charges";
    cdLabel.textColor = [UIColor whiteColor];
    cdLabel.font = [UIFont systemFontOfSize:12];
    [self.panelView addSubview:cdLabel];
    y += 24;

    UISwitch *cdSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(x, y, 51, 31)];
    cdSwitch.on = g_autoNoCD;
    cdSwitch.onTintColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
    [cdSwitch addTarget:self action:@selector(toggleNoCD:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:cdSwitch];

    UILabel *cdSw = [[UILabel alloc] initWithFrame:CGRectMake(x + 60, y + 4, 120, 20)];
    cdSw.text = @"Auto Clear";
    cdSw.textColor = [UIColor lightTextColor];
    cdSw.font = [UIFont systemFontOfSize:14];
    [self.panelView addSubview:cdSw];
}

- (void)toggleMenu {
    g_menuVisible = !g_menuVisible;
    self.panelView.hidden = !g_menuVisible;
}

- (void)toggleLimitDamage:(UISwitch *)sender {
    g_autoLimitDamage = sender.isOn;
    NSLog(@"[WHWB] Auto LimitDamage: %@", g_autoLimitDamage ? @"ON" : @"OFF");
}

- (void)toggleSkillAttack:(UISwitch *)sender {
    g_patchSkillAttack = sender.isOn;
    NSLog(@"[WHWB] Patch SkillAttack: %@", g_patchSkillAttack ? @"ON" : @"OFF");
}

- (void)toggleSkillReady:(UISwitch *)sender {
    g_patchSkillReady = sender.isOn;
    NSLog(@"[WHWB] Patch SkillReady: %@", g_patchSkillReady ? @"ON" : @"OFF");
}

- (void)toggleNoCD:(UISwitch *)sender {
    g_autoNoCD = sender.isOn;
    NSLog(@"[WHWB] Auto NoCD: %@", g_autoNoCD ? @"ON" : @"OFF");
}

@end

#pragma mark - 悬浮窗管理

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

        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 150, 270, 380)];
        g_menuView.alpha = 0;
        [keyWindow addSubview:g_menuView];

        [UIView animateWithDuration:0.3 animations:^{
            g_menuView.alpha = 1.0;
        }];

        NSLog(@"[WHWB] Menu shown");
    });
}

// Timer target for periodic game logic
@interface WHWBTimerTarget : NSObject
@end

@implementation WHWBTimerTarget

- (void)tick {
    // Auto LimitDamage - 通过 IL2CPP 找 RuntimeConfig 对象并改值
    if (g_autoLimitDamage) {
        // 留空: 需要运行时确认 IL2CPP API 可用后再补充
        // 备选: 通过内存搜索找到 RuntimeConfig 实例
    }

    // Auto No CD - 通过 IL2CPP 找 CharacterFiled 对象并清除 CD
    if (g_autoNoCD) {
        // 同上
    }
}

@end

static WHWBTimerTarget *g_timerTarget = nil;

#pragma mark - 初始化入口

__attribute__((constructor))
static void whwb_init() {
    NSLog(@"[WHWB] ====================================");
    NSLog(@"[WHWB] WHWB Helper v1.0 loaded");
    NSLog(@"[WHWB] ====================================");

    // 1. 初始化 IL2CPP API
    initIL2CPP();

    // 2. 安装 MSHookFunction hooks
    installHooks();

    // 3. 默认开启所有 patch
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;

    // 4. 显示悬浮窗 + 启动定时器
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();

        g_timerTarget = [[WHWBTimerTarget alloc] init];
        [NSTimer scheduledTimerWithTimeInterval:0.1
                                        target:g_timerTarget
                                      selector:@selector(tick)
                                      userInfo:nil
                                       repeats:YES];
    });

    NSLog(@"[WHWB] Init complete");
}
