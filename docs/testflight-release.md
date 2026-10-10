# TestFlight 发布流程（本机）

从仓库根目录运行 `Tools/release-testflight.py`。脚本在本机用 Apple Distribution `.p12` 和对应的 App Store profile 签名；App Store Connect `.p8` 仅用于查询 build、校验 IPA 和上传。对应的 App Store Connect app 是 **Mudi for Herdr**（`dev.mudi.mobile`），内部测试组是 `Mudi Internal`。

## 准备

本机已备有 Apple Distribution `.p12`、其密码文件、`dev.mudi.mobile` 的 App Store `.mobileprovision`，以及可访问 Mudi 的 App Store Connect `.p8`。这些签名文件放在仓库之外，不要提交到 Git；`.p8`、`.p12` 和密码文件权限设为 `600`。脚本从被 Git 忽略的 `Config/TestFlight.local.json` 读取 Key ID、Issuer ID 和文件路径（不在此文件存放密码或私钥内容）。首次配置：

```sh
cp -n Config/TestFlight.local.json.example Config/TestFlight.local.json
chmod 600 Config/TestFlight.local.json
# 首次使用时编辑 TestFlight.local.json，填入实际 ID 和文件路径。
```

## 发布

```sh
python3 Tools/release-testflight.py --upload
```

此命令归档、本地签名、导出 IPA、交给 Apple 校验，然后上传。若只想事先校验而不上传，运行 `python3 Tools/release-testflight.py`；每次运行都会重新构建。

脚本按运行时的 UTC 时间生成 `YYMMDDHH` build 号。归档前会查询该版本已可见的 TestFlight build：若已有同号或更高号，立即失败。上传要求 Git 工作区干净。脚本会打印保存归档、IPA 和日志的目录；Apple 接收上传后仍需等待处理。

脚本确认内部测试组 `Mudi Internal` 已设置为访问所有 build。新 build 处理完成且符合 Apple 的合规要求后，由 TestFlight 自动提供给该组。刚上传的 build 可能暂时查不到；同一 UTC 小时再次发布前应确认前一次的状态。`Info.plist` 的版本号由 Xcode 构建设置提供，IPA 会校验 `Mudi/Info.plist` 声明的 `ITSAppUsesNonExemptEncryption=false`。

## 测试

`Tools/test_release_testflight.py` 只覆盖纯逻辑（build 号、配置与权限、profile 分类、IPA 校验），不联网、不签名：

```sh
python3 Tools/test_release_testflight.py
```
