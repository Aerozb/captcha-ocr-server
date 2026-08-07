# 验证码 OCR 本机服务

本机图片验证码识别服务，**仅监听 `127.0.0.1:17898`**，不对外暴露。供自动登录脚本调用。

最初为腾讯企业邮箱（exmail.qq.com）的 4 位字母数字验证码而做，识别逻辑针对这种验证码调优。用在其他站点前需要重新评测。

## 环境要求

- Windows 10/11
- Python 3.10+（3.12 实测可用）

## 安装

```powershell
# 1. 建 venv 并安装依赖（ddddocr、rapidocr-onnxruntime、Pillow、numpy）
powershell -ExecutionPolicy Bypass -File scripts\install-dependencies.ps1

# 2. 注册开机自启（可选，但推荐）
powershell -ExecutionPolicy Bypass -File scripts\install-startup-task.ps1
```

装完可以自检：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify.ps1
```

## 手动启动

```powershell
# 后台启动（幂等，端口已健康就直接退出）
powershell -ExecutionPolicy Bypass -File scripts\start-ocr-server-hidden.ps1

# 前台启动，看实时输出，调试用
powershell -ExecutionPolicy Bypass -File scripts\start-ocr-server.ps1
```

首次启动要加载三个 ONNX 模型，约几秒。启动过程会记进 `logs\startup-history.log`。

## 接口

### `GET /`

健康检查。

```json
{"ok": true, "service": "exmail-captcha-ocr"}
```

### `POST /ocr`

请求体：

```json
{"image": "data:image/png;base64,iVBORw0KGgo..."}
```

`image` 接受 data URL 或裸 base64。

响应：

```json
{
  "ok": true,
  "text": "mGNS",
  "candidates": ["mGNS", "mgns", "mgNS", "MGNS", "..."],
  "default": "mgns",
  "beta": "mgns"
}
```

| 字段 | 说明 |
|------|------|
| `text` | 首选答案，已做大小写还原 |
| `candidates` | 候选列表，按可能性排序，第一个等于 `text` |
| `default` / `beta` | 两个 ddddocr 模型的原始输出，排查用 |

出错时返回 HTTP 500 和 `{"ok": false, "error": "..."}`。

## 重要：请使用 candidates 而不是只用 text

**字母识别准确率远高于大小写还原。** 在 12 张人工标注的真值集上：

| 口径 | 命中 |
|------|------|
| 忽略大小写（字母全对） | 11/12 |
| 严格区分大小写，且是首选答案 | 5/12 |
| 严格区分大小写，真值在前 5 候选内 | 9/12 |
| 严格区分大小写，真值在候选集中 | 11/12 |

也就是说，字母认对时正确的大小写基本都在 `candidates` 里，只是不一定排第一。

如果目标站点的验证码**区分大小写**（腾讯企业邮箱区分），调用方应该在提交被拒后**换下一个候选重试**，而不是反复提交同一个答案。这能把成功率从 5/12 提到 9/12，不需要任何模型改动。

参考实现见 `tencent-exmail-auto-login` 仓库的油猴脚本 `handleCaptcha()`：它判断验证码图片是否变化，图没变就取下一个候选（同一张图重新识别结果必然相同），图变了才重新调 OCR。

## 性能

单张 88ms（median 83ms），8 核机器实测，70 张样本平均。

从最初的 1295ms 优化而来，主要靠跳过 RapidOCR 的检测阶段（它占 478ms 却对这种图毫无必要）、关掉 ONNX Runtime 自旋等待、以及把线程数调到 4 而不是用满所有核。详见 `AGENTS.md` 的「性能背景」。

## 已知限制

- 只针对 4 位字母数字验证码，其他长度未测。
- 大小写还原是这个服务最弱的一环，同形字母（`cosuvwxzpkmnyj`）的判据依赖一个拟合当前分割方式的置信度阈值，换分割方式会失准。
- 有个别样本三个引擎会一致认错（B↔D 混淆），加权投票救不了。
- 真值集只有 12 张，上面所有比例的置信区间都很宽。

## 许可

MIT，见 `LICENSE`。
