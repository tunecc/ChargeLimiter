# 真机验收清单（fix-lockscreen-limit-inflow）

用户在 Relaxin 越狱 iPhone（iOS 17）上执行：

1. 安装含本修复的 roothide 包（构建：`./scripts/build_packages.sh`）
2. 限流等级设为 moderate 或 heavy，插电充电中
3. 锁屏 ≥30 分钟（最好跨一晚）
4. 逐条核对以下验收点

## 验收点

- [ ] A1 锁屏 ≥30 分钟后电流保持限流水平（未恢复到未限流电流）；可看悬浮窗/主页电流读数或系统电池图
- [ ] A2 亮屏后限流等级仍为用户设定的 moderate/heavy，未被自动改为 off 或默认档
- [ ] A3 拔线后限流解除（pref 回 off），再插线限流正常恢复
- [ ] A4 未插电静置 10 分钟，pref 保持 off（不出现未插电持续写限流回归）
- [ ] A5 关闭限流开关后，充电电流恢复未限流水平
- [ ] A6 切换限流等级（如 moderate → heavy）后，电流立即变化到新等级对应水平，无需等待下一次充电命令

## 对照原版

对照原版（v1.7 系）锁屏行为应一致：锁屏时限流保持。本 change 额外保证配置切换的原子性——两次独立的 `set_conf` 不再可能让 thermal mode 处于中间不一致状态。
