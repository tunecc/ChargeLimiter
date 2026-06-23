# 配置持久化问题修复总结

## 问题描述

用户报告：杀后台重开后，停充预设和滑动震动配置丢失。

## 诊断过程

### 1. 初步症状
- 深色模式设置丢失
- 停充预设丢失
- 滑动震动设置丢失

### 2. 错误定位
添加配置写入失败提示后，捕获到真实错误：
```
配置文件写入失败！
错误：你没有将文件存储到文件夹"ChargeLimiter"中的权限。
尝试路径：
/var/containers/Bundle/Application/.jbroot-33DB877990757C8F/var/mobile/Library/ChargeLimiter/com.chargelimiter.mod.plist
```

### 3. 根本原因

**路径解析错误**：
- `getConfigRootPathWithLibroot()` 在越狱环境使用 `getSharedDataRootPathWithLibroot()`
- roothide 环境下，`/var/mobile/Library/ChargeLimiter` 被 libroot 解析到：
  ```
  /var/containers/Bundle/Application/.jbroot-xxx/var/mobile/Library/ChargeLimiter/
  ```
- 这是 **app bundle 目录（只读）**，不是 **数据目录（可写）**

**架构限制**：
- daemon 以系统服务运行，需要访问配置文件
- daemon 无法直接访问 app 数据容器
- 即使 app 传递路径，roothide 的路径解析仍会出错

## 修复方案

### 1. 统一路径策略

**越狱环境**：配置/数据库/日志统一放在 daemon 可访问的共享目录
```
jbroot:/var/ChargeLimiter/
  ├── com.chargelimiter.mod.plist  (配置)
  ├── ChargeLimit.db               (数据库)
  └── charge_limiter.log           (日志)
```

**TrollStore**：使用 app 数据容器（没有 daemon，只有 app）
```
app数据容器/ChargeLimiter/
  ├── com.chargelimiter.mod.plist
  ├── ChargeLimit.db
  └── charge_limiter.log
```

### 2. roothide 数据根目录修正

```objective-c
// 旧路径（被解析到 bundle 内，只读）
static NSString* const kRoothideDataRoot = @"/var/mobile/Library/ChargeLimiter";

// 新路径（daemon 可写的共享目录）
static NSString* const kRoothideDataRoot = @"/var/ChargeLimiter";
```

### 3. 配置迁移修复

确保从 NSUserDefaults 迁移后立即写盘：
```objective-c
if (migrateLegacyUserDefaultsIntoPreferences(_preferences)) {
    _isDirty = YES;
    [self apply];  // 无条件写盘
}
```

## 代码改动

### 关键提交

1. **4a63403** - 修复配置迁移逻辑（无条件 apply）
2. **568b2a0** - 统一路径到共享目录

### 清理的试错代码

- 删除了深色模式恢复的症状修复
- 删除了显示值刷新的临时方案
- 删除了诊断日志
- 保留了核心修复逻辑

## 测试验证

1. 安装新版本：`ChargeLimiter_1.13.9_roothide_arm64e.deb`
2. 设置停充预设、滑动震动
3. 杀后台重开
4. 验证配置是否保留

## 技术要点

### iOS 沙盒机制
- App 数据容器：只有 app 可访问
- LaunchDaemon：以 root 运行，无法访问 app 数据容器
- 共享数据：必须放在 daemon 可访问的系统路径

### roothide 路径解析
- libroot API 将逻辑路径解析为物理路径
- `/var/mobile/Library/*` 被解析到 app bundle 内（只读）
- `/var/*` (不在 mobile 下) 被解析到可写的共享区域

### 多进程配置访问
- App 和 daemon 都需要读写配置
- 配置文件必须在两者都可访问的位置
- daemon 通过 app 传递的路径参数访问配置

## 经验教训

1. **诊断优先**：添加错误提示比盲目修复更有效
2. **理解架构**：必须理解 daemon 的运行环境和权限限制
3. **验证假设**：libroot 的路径解析行为需要实际测试验证
4. **保持简洁**：及时清理试错代码，保持代码库干净
