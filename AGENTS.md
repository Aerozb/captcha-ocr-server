# 验证码 OCR 本机服务

本文件是本仓库的**权威说明文件**，一切以本文件为准。`CLAUDE.md` 仅作指向，`README.md` 面向最终用户、内容更详尽；两者不冲突时使用说明以 `README.md` 为准，协作约定以本文件为准。

## 沟通语言

**一律用中文回答**（解释、分析、结论、报告、提问、总结都用中文）。代码、命令、日志原文、报错信息按原样保留，不用翻译。新写的文档也用中文。

## 这个服务干什么

本机图片验证码识别 HTTP 服务，**仅监听 `127.0.0.1:17898`**。多个自动登录脚本共用同一个实例，所以从原来的 `tencent-exmail-auto-login` 仓库独立出来。

最初为腾讯企业邮箱（exmail.qq.com）的 4 位字母数字验证码而做，识别逻辑（4 字符、大小写还原、同形字母判定）都是针对这种验证码调优的。用在其他站点前需要重新评测。

## 接口

`POST /ocr`，body `{"image": "data:image/png;base64,..."}`（也接受不带前缀的裸 base64）。

返回：

```json
{"ok": true, "text": "首选答案", "candidates": ["...", "..."], "default": "...", "beta": "..."}
```

`GET /` 是健康检查，返回 `{"ok": true, "service": "exmail-captcha-ocr"}`。

### 调用方应该用 candidates，不要只用 text

**字母识别准确率远高于大小写还原**：在 12 张人工标注的真值集上，忽略大小写有 11/12 正确，严格区分大小写只有 5/12。字母认对时，正确的大小写通常就在 `candidates` 里（11/12）。

所以调用方应该在提交失败后**换下一个候选重试**，而不是反复提交同一个答案。真值落在前 5 个候选的比例是 9/12。`tencent-exmail-auto-login` 的油猴脚本已按此实现，可作参考。

## 目录结构

| 路径 | 说明 |
|------|------|
| `ocr/exmail_captcha_ocr_server.py` | 服务本体，单文件 |
| `scripts/install-dependencies.ps1` | 建 venv 并装依赖 |
| `scripts/start-ocr-server.ps1` | 前台启动（调试用） |
| `scripts/start-ocr-server-hidden.ps1` | 后台启动，幂等，带启动历史日志 |
| `scripts/install-startup-task.ps1` | 注册开机自启计划任务 |
| `scripts/uninstall-startup-task.ps1` | 卸载计划任务 |
| `scripts/python-runtime.ps1` | 共享的 Python 解析（优先项目 `.venv`，校验 3.10+） |
| `scripts/verify.ps1` | 部署自检 |
| `requirements.txt` | ddddocr、rapidocr-onnxruntime、Pillow、numpy |
| `.local/` | **不入库**的测试资产：70 张样本、12 张人工标注真值集、诊断与评测脚本 |

## 怎么装

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-dependencies.ps1
powershell -ExecutionPolicy Bypass -File scripts\install-startup-task.ps1
```

需要 Python 3.10+。首次启动要加载三个 ONNX 模型，约几秒。

## 改动注意

- **只绑定回环地址**，不要改成对外监听。
- 改识别逻辑后必须跑回归，确认真值集准确率和 70 样本都不退化：
  ```powershell
  .venv\Scripts\python.exe .local\score_live.py          # 真值集严格命中
  .venv\Scripts\python.exe .local\check_candidates.py    # 候选覆盖率与排名
  .venv\Scripts\python.exe .local\regress_after_fix.py   # 70 样本无非 ASCII、无退化
  ```
- Windows 上 `.ps1` **必须带 UTF-8 BOM**。没有 BOM 时 PowerShell 5.1 按 ANSI(GBK) 解码，中文注释处解析就会乱，导致 `. python-runtime.ps1` 静默失效、报「Resolve-PythonRuntime 不是可识别的 cmdlet」。这个坑只在 `-File` 模式暴露，`-Command` 模式测不出来。
- 不要在启动脚本里内联 Python 解析逻辑。必须 dot-source `python-runtime.ps1` —— 它把项目 `.venv` 排在第一候选并校验 3.10+，内联版两者都会丢，后果是依赖装在 `.venv`、服务却用系统 Python。

## 性能背景

单张 88ms（median 83ms），从最初的 1295ms 优化而来。关键改动：

- **跳过 RapidOCR 的 DBNet 检测阶段**。它占 478ms/640ms，因为会把 130×53 的图放大到 736px 最小边再检测。而验证码上除字符没有别的墨迹，`split_boxes()` 用纯 numpy 约 1ms 就能定位。检测不但贵，还在 70 样本里有 25 个完全找不到文字，反而让大小写还原拿不到信号。
- **关掉 ONNX Runtime 的 intra-op 自旋等待**。每请求跑三个 session，一个推理时另两个的 worker 会空转抢核。关掉后 121ms → 73ms，输出逐字节不变。
- **线程数设 4**（不是全部逻辑核）。实测 1/2/3/4/6/8 线程分别 137/88/74/73/78/83ms，超过 4 之后同步开销大于收益。
- 三个 session 并发跑；启动时预热（预热图必须有四列墨迹，否则 `split_boxes` 找不到框、最贵的识别 session 仍是冷的）。

## 已知问题与陷阱

- **对比度兜底只在主引擎凑不出 4 位时触发，不要改成默认开启**。删除线和空心描边会让首字符笔画淡到主引擎漏读（输出只剩 3 位、候选集直接为空）。提高对比度能救回，但实测 70 样本中无条件启用会让 5 张原本正确的退化成 3 位（增强也会把相邻字符笔画连到一起），只有 2 张改善，净负。
- **同形字母的大小写判据是脆的**。`cosuvwxzpkmnyj` 大小写字形基本相同，只能靠相对高度区分，而整行识别器会把行高归一化掉——它对这些字母输出的大小写不携带信息，只反映模型自身的全大写倾向。现在靠逐字符 crop 置信度阈值 `0.60` 判定，但**这个阈值是拟合当前分割方式的**：换成按墨迹投影谷底切分后，`live_06` 首字母置信度会从 0.540 漂到 0.616，越过阈值产生误大写。
- **三种几何判据实测全部不可用**。相对行高、相对最高框、绝对像素高度都有重叠（最好情况错分 6/22）。原因是全小写或全大写的图里没有参照物（`pgbp`、`ynyn` 的最高框本身就是小写字母），加上 p/y/g/j 的降部让小写框高追平大写。
- **`live_10` 未解决**：真值 `NEDG`，三个引擎一致读成 `nEBG`，B↔D 混淆。三引擎一致犯错说明加权投票救不了，需要换模型或专门训练。
- **真值集只有 12 张、21 个同形字母位置**，样本量小，所有比例的置信区间都很宽。对外引用这些数字前建议先扩充标注。

## 调研过的开源方案（都不可用）

| 方案 | 在本项目真值集上实测 |
|------|---------------------|
| [xiaolv/ocr-captcha](https://huggingface.co/xiaolv/ocr-captcha) small | 1/12 |
| 同上 big | 0/12 |
| 现有 ddddocr + RapidOCR 集成 | 5/12 严格 / 11/12 忽略大小写 |

两个 HuggingFace 模型输出全小写、字符数在 3~5 之间不稳。它们是 804×32 宽幅行识别器，130×53 的图被拉伸到宽高比 25:1 严重失真；训练数据是「常见验证码」，没见过 exmail 的删除线+字符粘连+空心描边字形。README 声称的「精度接近 100%」在本项目数据上不成立。所以「用它自动标注再训专用模型」也不可行——会把它的错误当标签学进去。

[bojone/n2n-ocr-for-qqcaptcha](https://github.com/bojone/n2n-ocr-for-qqcaptcha) 是旧版 QQ 验证码、仅 26 个小写类、无预训练权重、Keras 1.x/Python 2。

[sml2h3/dddd_trainer](https://github.com/sml2h3/dddd_trainer) 技术上可行：已确认 `ddddocr.DdddOcr` 支持 `import_onnx_path` / `charsets_path`，训练产物能零新增依赖插进现有服务。瓶颈是需要几千张人工标注。
