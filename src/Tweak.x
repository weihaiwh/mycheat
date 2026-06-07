#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>

// ============================================================
//  WHWB Tweak v2.0 - iOS IL2CPP Game Hack
//  Target: com.jyjh.whwb (FrameSync based game)
//  Platform: iOS arm64e, Dopamine rootless
//  Hook: CydiaSubstrate (MSHookFunction)
// ============================================================

#pragma mark - 偏移量 (从 dump.cs 提取)
// 基址通过 _dyld_get_image_header 获取
static uintptr_t OFFSET_CHECK_SKILL_ATTACK = 0x2a9218;
static uintptr_t OFFSET_CHECK_SKILL_READY   = 0x2a9b08;

#pragma mark - 全局状态

static BOOL g_patchSkillAttack = NO;
static BOOL g_patchSkillReady  = NO;
static BOOL g_autoLimitDamage  = NO;
static BOOL g_autoNoCD         = NO;

// limitDamage 目标值: RawValue = 131072000, AsLong = 2000
static int64_t TARGET_RAW_VALUE = 131072000LL;

#pragma mark - IL2CPP API 函数指针

typedef void* (*il2cpp_class_from_name_t)(void *image, const char *ns, const char *name);
typedef void* (*il2cpp_class_get_method_from_name_t)(void *klass, const char *name, int args);
typedef void* (*il2cpp_method_get_param_count_t)(void *method);
typedef void* (*il2cpp_class_get_field_from_name_t)(void *klass, const char *name);
typedef int32_t (*il2cpp_field_get_offset_t)(void *field);
typedef void* (*il2cpp_domain_get_t)(void);
typedef void* (*il2cpp_domain_get_assemblies_t)(void *domain, size_t *size);
typedef void* (*il2cpp_assembly_get_image_t)(void *assembly);
typedef const char* (*il2cpp_image_get_name_t)(void *image);
typedef void* (*il2cpp_object_new_t)(void *klass);
typedef void* (*il2cpp_class_get_type_t)(void *klass);
typedef void* (*il2cpp_type_get_object_t)(void *type);
typedef void* (*il2cpp_runtime_class_init_t)(void *klass);
typedef void* (*il2cpp_field_set_value_t)(void *obj, void *field, void *value);
typedef void* (*il2cpp_field_get_value_t)(void *obj, void *field, void *value);
typedef void** (*il2cpp_class_get_static_field_data_t)(void *klass);

static il2cpp_class_from_name_t             s_classFromName = NULL;
static il2cpp_class_get_method_from_name_t   s_getMethodFromName = NULL;
static il2cpp_class_get_field_from_name_t    s_getFieldFromName = NULL;
static il2cpp_field_get_offset_t             s_fieldGetOffset = NULL;
static il2cpp_domain_get_t                   s_domainGet = NULL;
static il2cpp_domain_get_assemblies_t        s_domainGetAssemblies = NULL;
static il2cpp_assembly_get_image_t           s_assemblyGetImage = NULL;
static il2cpp_image_get_name_t              s_imageGetName = NULL;
static il2cpp_runtime_class_init_t           s_runtimeClassInit = NULL;
static il2cpp_class_get_type_t              s_classGetType = NULL;

#pragma mark - IL2CPP 初始化

static void *s_il2cppHandle = NULL;

static BOOL initIL2CPP() {
    if (s_il2cppHandle) return YES;

    // 尝试从主程序加载
    s_il2cppHandle = dlopen(NULL, RTLD_LAZY);
    if (!s_il2cppHandle) {
        NSLog(@"[WHWB] dlopen failed");
        return NO;
    }

    s_classFromName = (il2cpp_class_from_name_t)dlsym(s_il2cppHandle, "il2cpp_class_from_name");
    s_getMethodFromName = (il2cpp_class_get_method_from_name_t)dlsym(s_il2cppHandle, "il2cpp_class_get_method_from_name");
    s_getFieldFromName = (il2cpp_class_get_field_from_name_t)dlsym(s_il2cppHandle, "il2cpp_class_get_field_from_name");
    s_fieldGetOffset = (il2cpp_field_get_offset_t)dlsym(s_il2cppHandle, "il2cpp_field_get_offset");
    s_domainGet = (il2cpp_domain_get_t)dlsym(s_il2cppHandle, "il2cpp_domain_get");
    s_domainGetAssemblies = (il2cpp_domain_get_assemblies_t)dlsym(s_il2cppHandle, "il2cpp_domain_get_assemblies");
    s_assemblyGetImage = (il2cpp_assembly_get_image_t)dlsym(s_il2cppHandle, "il2cpp_assembly_get_image");
    s_imageGetName = (il2cpp_image_get_name_t)dlsym(s_il2cppHandle, "il2cpp_image_get_name");
    s_runtimeClassInit = (il2cpp_runtime_class_init_t)dlsym(s_il2cppHandle, "il2cpp_runtime_class_init");

    if (!s_classFromName || !s_getFieldFromName || !s_fieldGetOffset || !s_domainGet) {
        NSLog(@"[WHWB] Some IL2CPP APIs not found");
        NSLog(@"[WHWB] classFromName=%p getFieldFromName=%p fieldGetOffset=%p domainGet=%p",
              s_classFromName, s_getFieldFromName, s_fieldGetOffset, s_domainGet);
        return NO;
    }

    NSLog(@"[WHWB] IL2CPP APIs loaded successfully");
    return YES;
}

#pragma mark - 查找 IL2CPP Image

static void *findImage(const char *targetName) {
    if (!s_domainGet || !s_domainGetAssemblies || !s_assemblyGetImage || !s_imageGetName) return NULL;

    void *domain = s_domainGet();
    if (!domain) return NULL;

    size_t asmCount = 0;
    void **assemblies = (void **)s_domainGetAssemblies(domain, &asmCount);

    for (size_t i = 0; i < asmCount; i++) {
        void *image = s_assemblyGetImage(assemblies[i]);
        if (!image) continue;
        const char *name = s_imageGetName(image);
        if (name && strstr(name, targetName)) {
            NSLog(@"[WHWB] Found image: %s", name);
            return image;
        }
    }
    return NULL;
}

#pragma mark - Hook 函数: CheckSkillAttackCanUse / CheckSkillIsReady

static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *characterField, void *states);
static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *characterField, void *states);

static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillAttack) return true;
    return orig_CheckSkillAttackCanUse(frame, stateType, characterField, states);
}

static bool hook_CheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_patchSkillReady) return true;
    return orig_CheckSkillIsReady(frame, stateType, characterField, states);
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

#pragma mark - 安装 MSHookFunction hooks

static void installHooks() {
    uintptr_t base = getBaseAddress();
    if (base == 0) {
        NSLog(@"[WHWB] ERROR: base address is 0");
        return;
    }

    void *addrAttack = (void *)(base + OFFSET_CHECK_SKILL_ATTACK);
    MSHookFunction(addrAttack,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);
    NSLog(@"[WHWB] Hooked CheckSkillAttackCanUse at %p", addrAttack);

    void *addrReady = (void *)(base + OFFSET_CHECK_SKILL_READY);
    MSHookFunction(addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);
    NSLog(@"[WHWB] Hooked CheckSkillIsReady at %p", addrReady);
}

#pragma mark - limitDamage 修改

static BOOL setLimitDamage() {
    if (!initIL2CPP()) return NO;

    void *image = findImage("FrameSync");
    if (!image) {
        NSLog(@"[WHWB] FrameSync image not found");
        return NO;
    }

    // 找 RuntimeConfig 类
    void *runtimeConfigClass = s_classFromName(image, "FrameSync", "RuntimeConfig");
    if (!runtimeConfigClass) {
        NSLog(@"[WHWB] RuntimeConfig class not found");
        return NO;
    }

    // 初始化类
    if (s_runtimeClassInit) {
        s_runtimeClassInit(runtimeConfigClass);
    }

    // 找 limitDamage 字段
    void *limitDamageField = s_getFieldFromName(runtimeConfigClass, "limitDamage");
    if (!limitDamageField) {
        NSLog(@"[WHWB] limitDamage field not found");
        return NO;
    }

    int32_t offset = s_fieldGetOffset(limitDamageField);
    NSLog(@"[WHWB] limitDamage offset: %d (0x%x)", offset, offset);

    // 找 RuntimeConfig 的静态实例或通过 findObjects
    // 方法: 遍历 assemblies 找已创建的 RuntimeConfig 对象
    // 简化: 直接通过 GC Handles 或者使用 il2cpp_field_get_value on static instance

    // 尝试获取静态字段数据
    // RuntimeConfig 看起来是普通 class，可能有 static instance
    // 偏移 0x40 是 limitDamage 在实例中的偏移

    // 方法2: 通过类遍历 GC handles
    typedef void* (*il2cpp_class_get_instance_size_t)(void *klass);
    auto getClassSize = (il2cpp_class_get_instance_size_t)dlsym(s_il2cppHandle, "il2cpp_class_get_instance_size");

    typedef int32_t (*il2cpp_class_get_field_count_t)(void *klass);
    auto getFieldCount = (il2cpp_class_get_field_count_t)dlsym(s_il2cppHandle, "il2cpp_class_get_field_count");

    NSLog(@"[WHWB] RuntimeConfig class=%p, limitDamage field=%p, offset=%d",
          runtimeConfigClass, limitDamageField, offset);

    if (getClassSize) {
        void *size = getClassSize(runtimeConfigClass);
        NSLog(@"[WHWB] RuntimeConfig instance size: %ld", (long)size);
    }

    // 读取当前值 - 需要找到实例
    // RuntimeConfig 通常有一个 static Instance 或 s_Instance 字段
    void *instanceField = s_getFieldFromName(runtimeConfigClass, "s_Instance");
    if (!instanceField) instanceField = s_getFieldFromName(runtimeConfigClass, "Instance");
    if (!instanceField) instanceField = s_getFieldFromName(runtimeConfigClass, "_instance");
    if (!instanceField) instanceField = s_getFieldFromName(runtimeConfigClass, "current");

    if (instanceField) {
        int32_t instOffset = s_fieldGetOffset(instanceField);
        NSLog(@"[WHWB] Found instance field at offset %d", instOffset);

        // 静态字段的 offset 就是它在静态数据区的偏移
        // 获取静态字段数据区
        typedef void** (*il2cpp_class_get_static_field_data_t)(void *klass);
        auto getStaticData = (il2cpp_class_get_static_field_data_t)dlsym(s_il2cppHandle, "il2cpp_class_get_static_field_data");

        if (getStaticData) {
            void **staticData = getStaticData(runtimeConfigClass);
            if (staticData) {
                void *instance = staticData[instOffset / sizeof(void *)];
                if (instance) {
                    NSLog(@"[WHWB] Found RuntimeConfig instance at %p", instance);
                    // 修改 limitDamage (offset 0x40 = 64)
                    // FP struct: RawValue is the first int64 at offset 0
                    int64_t *rawValuePtr = (int64_t *)((uintptr_t)instance + offset);
                    NSLog(@"[WHWB] Current RawValue: %lld", *rawValuePtr);
                    *rawValuePtr = TARGET_RAW_VALUE;
                    NSLog(@"[WHWB] Set RawValue to: %lld (verify: %lld)", TARGET_RAW_VALUE, *rawValuePtr);
                    return YES;
                }
            }
        }
    }

    NSLog(@"[WHWB] Could not find RuntimeConfig instance, trying offset scan");
    return NO;
}

#pragma mark - 无CD / 满充能

static BOOL clearSkillCDs() {
    if (!initIL2CPP()) return NO;

    void *image = findImage("FrameSync");
    if (!image) return NO;

    void *charFiledClass = s_classFromName(image, "FrameSync", "CharacterFiled");
    if (!charFiledClass) {
        NSLog(@"[WHWB] CharacterFiled class not found");
        return NO;
    }

    if (s_runtimeClassInit) s_runtimeClassInit(charFiledClass);

    // SkillInfo 包含 Skill1~Skill6 + SkillSprint
    // 每个 SkillStateData 有: CoolDown(FP), Count(Int16), CountMax(Int16)
    // 需要: CoolDown.RawValue = 0, Count = CountMax

    void *skillInfoField = s_getFieldFromName(charFiledClass, "SkillInfo");
    if (!skillInfoField) {
        NSLog(@"[WHWB] SkillInfo field not found");
        return NO;
    }

    int32_t skillInfoOffset = s_fieldGetOffset(skillInfoField);
    NSLog(@"[WHWB] SkillInfo offset: %d", skillInfoOffset);

    // 类似 limitDamage 的逻辑，需要找到 CharacterFiled 实例
    // CharacterFiled 是 struct，可能作为字段嵌入其他对象

    return NO; // 需要实例才能操作
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
    CGFloat pw = 280, ph = 360;
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
    title.text = @"WHWB Helper v2.0";
    title.textColor = [UIColor colorWithRed:0.4 green:0.75 blue:1.0 alpha:1.0];
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:title];
    y += 36;

    // 分割线
    [self addSeparatorAt:y];
    y += 10;

    // Skill Patches 标签
    UILabel *skLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 18)];
    skLabel.text = @"Skill Patches";
    skLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    skLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.panelView addSubview:skLabel];
    y += 24;

    y = [self addSwitchAt:y x:x w:w label:@"AttackCanUse → true" isOn:g_patchSkillAttack action:@selector(toggleAttack:) color:[UIColor colorWithRed:1.0 green:0.35 blue:0.2 alpha:1.0]];

    y = [self addSwitchAt:y x:x w:w label:@"IsReady → true" isOn:g_patchSkillReady action:@selector(toggleReady:) color:[UIColor colorWithRed:1.0 green:0.6 blue:0.1 alpha:1.0]];

    y += 6;
    [self addSeparatorAt:y];
    y += 10;

    // LimitDamage 区
    UILabel *ldLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 18)];
    ldLabel.text = @"LimitDamage (RawValue=131072000)";
    ldLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    ldLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [self.panelView addSubview:ldLabel];
    y += 24;

    y = [self addSwitchAt:y x:x w:w label:@"Auto Set LimitDamage" isOn:g_autoLimitDamage action:@selector(toggleLimitDmg:) color:[UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1.0]];

    // Set 按钮
    UIButton *setBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    setBtn.frame = CGRectMake(x, y, w, 36);
    setBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.95 alpha:1.0];
    setBtn.layer.cornerRadius = 8;
    [setBtn setTitle:@"Set LimitDamage Now" forState:UIControlStateNormal];
    setBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [setBtn addTarget:self action:@selector(setLimitDamageNow) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:setBtn];
    y += 46;

    // 状态标签
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 40)];
    self.statusLabel.text = @"Ready";
    self.statusLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.numberOfLines = 2;
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
    NSLog(@"[WHWB] Patch SkillAttack: %@", g_patchSkillAttack ? @"ON" : @"OFF");
}

- (void)toggleReady:(UISwitch *)sender {
    g_patchSkillReady = sender.isOn;
    NSLog(@"[WHWB] Patch SkillReady: %@", g_patchSkillReady ? @"ON" : @"OFF");
}

- (void)toggleLimitDmg:(UISwitch *)sender {
    g_autoLimitDamage = sender.isOn;
    NSLog(@"[WHWB] Auto LimitDamage: %@", g_autoLimitDamage ? @"ON" : @"OFF");
}

- (void)setLimitDamageNow {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = setLimitDamage();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusLabel.text = ok ? @"LimitDamage SET OK!" : @"LimitDamage SET FAILED (see log)";
            self.statusLabel.textColor = ok ? [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1.0] : [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:1.0];
        });
    });
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

        g_menuView = [[WHWBMenuView alloc] initWithFrame:CGRectMake(10, 120, 290, 420)];
        g_menuView.alpha = 0;
        [keyWindow addSubview:g_menuView];

        [UIView animateWithDuration:0.3 animations:^{
            g_menuView.alpha = 1.0;
        }];
    });
}

#pragma mark - 定时器 (自动模式)

@interface WHWBTimerTarget : NSObject
@end

@implementation WHWBTimerTarget

- (void)tick {
    if (g_autoLimitDamage) {
        setLimitDamage();
    }
}

@end

static WHWBTimerTarget *g_timerTarget = nil;

#pragma mark - 入口

__attribute__((constructor))
static void whwb_init() {
    NSLog(@"[WHWB] ====================================");
    NSLog(@"[WHWB] WHWB Helper v2.0 loaded");
    NSLog(@"[WHWB] ====================================");

    // 1. 初始化 IL2CPP API
    initIL2CPP();

    // 2. 安装 MSHookFunction hooks
    installHooks();

    // 3. 默认开启 skill patches
    g_patchSkillAttack = YES;
    g_patchSkillReady = YES;

    // 4. 延迟显示UI + 启动定时器
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        showMenu();

        g_timerTarget = [[WHWBTimerTarget alloc] init];
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                        target:g_timerTarget
                                      selector:@selector(tick)
                                      userInfo:nil
                                       repeats:YES];
    });

    NSLog(@"[WHWB] Init complete");
}
