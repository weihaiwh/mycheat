# WHWB Tweak 安装指南

## 设备信息
- iPhone 13 Pro Max, iOS 15.6
- Dopamine 无根越狱 (rootless)
- Sileo 包管理器

---

## 一、在手机上准备 Theos 编译环境 (可选，GitHub Actions 已编译好)

如果你想在手机上自己编译，需要以下步骤：

### 1. SSH 连接到手机
在电脑终端执行：
```bash
ssh root@你的手机IP
# 默认密码: alpine (强烈建议改密码: passwd)
```

### 2. 安装基础依赖
```bash
apt update
apt install curl git perl make dpkg
```

### 3. 安装 Theos
```bash
export THEOS=/var/jb/theos
git clone --recursive https://github.com/theos/theos.git $THEOS
```

### 4. 安装 iOS SDK
```bash
# 从社区下载 SDK (需要根据 iOS 版本选择)
mkdir -p $THEOS/sdks
# 将 SDK 复制到 $THEOS/sdks/ 目录
```

### 5. 编译
```bash
cd /var/jb/whwb-tweak/src
export THEOS=/var/jb/theos
make package
```

---

## 二、安装已编译好的 Tweak (推荐)

### 方法 A: 通过 DEB 包安装 (推荐)

1. 将 WHWB.deb 传到手机：
```bash
# 电脑上执行
scp WHWB.deb root@你的手机IP:/var/jb/
```

2. SSH 到手机安装：
```bash
ssh root@你的手机IP
dpkg -i /var/jb/WHWB.deb
```

3. 重启游戏或 respring：
```bash
killall -9 backboardd
```

### 方法 B: 手动安装 dylib

1. 将 WHWB.dylib 传到手机：
```bash
scp WHWB.dylib root@你的手机IP:/var/jb/Library/MobileSubstrate/DynamicLibraries/
```

2. 创建 plist 配置文件：
```bash
ssh root@你的手机IP
cat > /var/jb/Library/MobileSubstrate/DynamicLibraries/WHWB.plist << 'EOF'
{ Filter = { Bundles = ( "com.jyjh.whwb" ); }; }
EOF
```

3. 设置权限：
```bash
chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/WHWB.dylib
chmod 644 /var/jb/Library/MobileSubstrate/DynamicLibraries/WHWB.plist
```

4. 注入或重启游戏

### 方法 C: 使用 Sileo 安装 deb

1. 把 deb 放到手机上
2. 用 Filza 等文件管理器点击 deb → 安装
3. 重启游戏

---

## 三、使用说明

### 悬浮窗功能
进入游戏后左上角会出现蓝色 "W" 按钮：
- 点击 "W" → 展开/收起菜单面板

### 开关说明
| 开关 | 功能 | 默认 |
|------|------|------|
| AttackCanUse → true | 所有技能攻击可用 (hook CheckSkillAttackCanUse) | ✅ 开 |
| IsReady → true | 所有技能就绪 (hook CheckSkillIsReady) | ✅ 开 |
| Auto Set LimitDamage | 自动设置 limitDamage = 131072000 | ❌ 关 |
| Set LimitDamage Now | 手动触发一次设置 | 按钮 |

### 日志查看
```bash
# SSH 到手机后
tail -f /var/mobile/Library/Logs/WHWB.log
# 或通过控制台看 NSLog
```

---

## 四、常见问题

### Q: 注入后游戏闪退
A: 偏移量可能不匹配。需要用对应版本的 dump.cs 确认偏移。
当前偏移: CheckSkillAttackCanUse=0x2a9218, CheckSkillIsReady=0x2a9b08
如果游戏更新了，偏移会变，需要重新从 dump.cs 提取。

### Q: 悬浮窗没出现
A: 等 3-5 秒，游戏完全加载后才显示。检查日志确认 tweak 是否加载。

### Q: LimitDamage 设置失败
A: 查看 NSLog 日志，可能是 RuntimeConfig 的实例字段名不同，
需要根据实际 dump 确认 Instance/s_Instance 字段名。

### Q: 卸载
```bash
dpkg -r com.whwb.tweak
# 或手动删除
rm /var/jb/Library/MobileSubstrate/DynamicLibraries/WHWB.dylib
rm /var/jb/Library/MobileSubstrate/DynamicLibraries/WHWB.plist
```
