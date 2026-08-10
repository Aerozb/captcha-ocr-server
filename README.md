# 验证码 OCR 本机服务

本机图片验证码识别服务，**仅监听 `127.0.0.1:17898`**，不对外暴露。供自动登录脚本调用。

最初为腾讯企业邮箱（exmail.qq.com）的 4 位字母数字验证码而做，识别逻辑针对这种验证码调优。用在其他站点前需要重新评测。

## 一键管理入口（推荐）

Windows 用户直接双击仓库根目录的 `OCR服务管理.bat`，即可在一个菜单里完成安装、启动、停止、自检和开机自启配置，不需要手动输入 PowerShell 命令。

首次使用推荐按这个顺序执行：

1. `[1] 安装或更新依赖`
2. `[6] 部署自检`
3. `[2] 后台启动服务`
4. `[7] 安装开机自启`（可选，但推荐）

每项任务执行完都会在当前窗口显示成功或失败，按回车就会回到主菜单，可以继续执行下一项。菜单顶部还会显示服务、虚拟环境和开机自启的当前状态。

只有“前台调试启动”会打开一个新的可见窗口，用来持续显示实时输出。原来的管理窗口会轮询健康接口，因此仍会明确报告服务是否启动成功；启动错误则保留在新窗口中，便于直接查看。

## 环境要求

- Windows 10/11
- Python 3.10+（3.12 实测可用）

## 命令行安装（进阶）

```powershell
# 1. 建 venv 并安装依赖（ddddocr、rapidocr-onnxruntime、Pillow、numpy）
powershell -ExecutionPolicy Bypass -File scripts\安装依赖.ps1

# 2. 部署自检
powershell -ExecutionPolicy Bypass -File scripts\部署自检.ps1

# 3. 注册开机自启（可选，但推荐）
powershell -ExecutionPolicy Bypass -File scripts\安装开机自启.ps1
```

## 命令行启动与停止（进阶）

```powershell
# 后台启动（幂等，端口已健康就直接退出）
powershell -ExecutionPolicy Bypass -File scripts\启动服务-后台.ps1

# 前台启动，看实时输出，调试用
powershell -ExecutionPolicy Bypass -File scripts\启动服务-前台调试.ps1

# 停止本仓库启动的 OCR 服务
powershell -ExecutionPolicy Bypass -File scripts\停止服务.ps1
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

出错时返回 HTTP 500 和 `{"ok": false, "error": "..."}`,例如 base64 不合法时是 `{"ok": false, "error": "Incorrect padding"}`。服务不会因为单次请求出错而崩溃。

### 调用示例

Python：

```python
import base64, json, urllib.request

with open("captcha.png", "rb") as f:
    payload = {"image": "data:image/png;base64," + base64.b64encode(f.read()).decode()}

req = urllib.request.Request(
    "http://127.0.0.1:17898/ocr",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)
result = json.loads(urllib.request.urlopen(req, timeout=20).read())
print(result["text"], result["candidates"][:5])
```

浏览器 / 油猴脚本（需要 `@grant GM_xmlhttpRequest`,因为这是跨源请求）：

```javascript
GM_xmlhttpRequest({
  method: 'POST',
  url: 'http://127.0.0.1:17898/ocr',
  headers: { 'Content-Type': 'application/json' },
  data: JSON.stringify({ image: canvas.toDataURL('image/png') }),
  timeout: 15000,
  onload: (res) => {
    const { text, candidates } = JSON.parse(res.responseText);
    // 提交 candidates[0]；被拒后依次试 candidates[1]、[2]...
  },
});
```

服务已设 `Access-Control-Allow-Origin: *`,浏览器端可直接调用。

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

8 核机器实测、70 张样本平均：**最近一次 mean 185–199ms**，最初未优化版本约 1295ms。

注意这个数字**随机器状态波动很大**——同一份代码在同一台机器上测过 88ms、104ms、185ms。它用来衡量优化的相对效果，不适合当作可复现的性能承诺。需要准确数字时现测：

```powershell
.venv\Scripts\python.exe .local\bench_one.py ocr\exmail_captcha_ocr_server.py
```

提速主要靠跳过 RapidOCR 的检测阶段（它占了大部分耗时却对这种图毫无必要）、关掉 ONNX Runtime 自旋等待、以及把线程数调到 4 而不是用满所有核。详见 `AGENTS.md` 的「性能背景」。

## 排障

**服务没响应**

```powershell
Invoke-RestMethod http://127.0.0.1:17898/
Get-Content logs\startup-history.log -Tail 20
Get-ScheduledTask -TaskName ExmailCaptchaOcrServer
```

`startup-history.log` 是追加式的，每次启动都留记录，包括用了哪个 Python、进程 PID、几秒就绪、或者提前退出的错误。开机后服务不在时先看这个文件。

**改了代码但行为没变**

通常是旧进程仍在运行。最简单的处理方式是双击 `OCR服务管理.bat`，然后选择 `[5] 重启后台服务`。命令行方式：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\停止服务.ps1
powershell -ExecutionPolicy Bypass -File scripts\启动服务-后台.ps1
```

服务已启用端口排他，同一端口上的第二个实例会直接报告占用。正常运行时仍会看到**两个** python 进程且互为父子——`.venv\Scripts\python.exe` 是转发 stub，会拉起基础解释器作为子进程，这是 venv 的正常行为。

**移动过项目目录**

计划任务里存的是绝对路径，移动后会失效。在新位置重跑 `安装开机自启.ps1` 即可（它用 `-Force` 覆盖注册）。`.venv` 里也有绝对路径，最好删掉重建。

**报「Resolve-PythonRuntime 不是可识别的 cmdlet」**

`.ps1` 文件的 UTF-8 BOM 丢了。没有 BOM 时 PowerShell 5.1 按 GBK 解码，中文注释处解析出错，导致 dot-source 静默失效。用带 BOM 的编码重存即可。

## 已知限制

- 只针对 4 位字母数字验证码，其他长度未测。
- **大小写还原是这个服务最弱的一环**，同形字母（`cosuvwxzpkmnyj`）的判据依赖一个拟合当前分割方式的置信度阈值，换分割方式会失准。这也是为什么应该用 `candidates` 而不是只用 `text`。
- 有个别样本三个引擎会一致认错（B↔D 混淆），加权投票救不了，需要换模型或专门训练。
- **真值集只有 12 张，上面所有比例的置信区间都很宽。** 这些数字用来判断改动方向够用，但不适合当作对外承诺的准确率。
- 调研过的现成开源模型（HuggingFace 上的通用验证码模型）在本项目数据上实测比现有方案差得多，详见 `AGENTS.md`。
