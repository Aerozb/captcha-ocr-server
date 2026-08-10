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
| `OCR服务管理.bat` | 面向 Windows 新用户的根目录统一入口，双击后进入循环菜单 |
| `ocr/exmail_captcha_ocr_server.py` | 服务本体，单文件 |
| `tests/test_server.py` | HTTP 请求校验、路由、CORS、端口排他与启动预热的自动化测试 |
| `scripts/ocr-service-menu.ps1` | 管理菜单实现，统一调用各功能脚本并显示结果 |
| `scripts/安装依赖.ps1` | 建 venv 并装依赖 |
| `scripts/启动服务-前台调试.ps1` | 前台启动（调试用） |
| `scripts/启动服务-后台.ps1` | 后台启动，幂等，带启动历史日志 |
| `scripts/停止服务.ps1` | 只停止命令行中匹配本仓库服务脚本的 Python 进程 |
| `scripts/安装开机自启.ps1` | 注册开机自启计划任务 |
| `scripts/卸载开机自启.ps1` | 卸载计划任务 |
| `scripts/公共-查找Python.ps1` | 共享的 Python 解析（优先项目 `.venv`，校验 3.10+） |
| `scripts/部署自检.ps1` | 部署自检 |
| `requirements.txt` | ddddocr、rapidocr-onnxruntime、Pillow、numpy |
| `.local/` | **不入库**的测试资产：70 张样本、12 张人工标注真值集、诊断与评测脚本 |

## 怎么装

面向最终用户的首选方式是双击根目录 `OCR服务管理.bat`，按菜单提示依次执行 `[1] 安装或更新依赖`、`[6] 部署自检`、`[2] 后台启动服务`；需要开机自动运行时再执行 `[7] 安装开机自启`。

命令行方式仍保留：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\安装依赖.ps1
powershell -ExecutionPolicy Bypass -File scripts\部署自检.ps1
powershell -ExecutionPolicy Bypass -File scripts\启动服务-后台.ps1
powershell -ExecutionPolicy Bypass -File scripts\安装开机自启.ps1
```

需要 Python 3.10+。首次启动要加载三个 ONNX 模型，约几秒。

### 根目录管理入口约定

- `OCR服务管理.bat` 只负责切换到仓库根目录并启动 `scripts/ocr-service-menu.ps1`，不在 BAT 内堆复杂业务逻辑。
- 安装依赖、自检、后台启动、停止和计划任务配置都在当前窗口执行，菜单根据子进程退出码显示成功或失败，完成后回到根目录并继续循环。
- 前台调试是唯一打开新窗口的操作。原菜单窗口通过轮询 `GET http://127.0.0.1:17898/` 判断是否真正就绪；错误输出留在新窗口，不能只把“窗口已创建”当作启动成功。
- 停止脚本只匹配命令行中包含本仓库 `ocr/exmail_captcha_ocr_server.py` 绝对路径的 Python 进程，不按进程名批量终止其他 Python 程序。

## 改动注意

- **只绑定回环地址**，不要改成对外监听。

- **改完代码必须重启服务，否则 17898 端口上跑的还是旧进程。** 这一步极易漏：进程内测试（直接 import 模块）拿到的是新代码，但走 HTTP 的结果仍来自旧进程，两者数字不一致时很容易误判成「改动无效」或反过来把旧结果当成新成果。启动脚本还有「端口已健康就直接退出」的幂等快路径，会让人以为服务已经是新的。

  服务现在使用 `OcrHttpServer` 关闭 `SO_REUSEADDR`，并在 Windows 上启用 `SO_EXCLUSIVEADDRUSE`：同一端口的第二个实例会立即绑定失败，不再与旧实例静默并存。重启时仍要先确认旧进程全部退出，否则新进程会明确报端口占用：

  ```powershell
  # 停掉本仓库启动的所有服务进程，再重新后台启动
  powershell -ExecutionPolicy Bypass -File scripts\停止服务.ps1
  powershell -ExecutionPolicy Bypass -File scripts\启动服务-后台.ps1
  ```

  启动后核对 `logs\startup-history.log` 里的 `using python:` 一行确实指向本仓库的 `.venv`。注意正常情况下会看到**两个** python 进程且互为父子：`.venv\Scripts\python.exe` 是转发 stub，会拉起基础解释器作为子进程，这是 venv 的正常行为，不是多实例。

- 改 HTTP 服务、请求解析或启动流程后，先跑标准库自动化测试：

  ```powershell
  .venv\Scripts\python.exe -m unittest discover -s tests -v
  ```

- 改识别逻辑后必须跑回归，确认真值集准确率和 70 样本都不退化：

  ```powershell
  .venv\Scripts\python.exe .local\score_live.py          # 真值集严格命中，当前 5/12 严格、11/12 忽略大小写
  .venv\Scripts\python.exe .local\check_candidates.py    # 候选覆盖率与排名，当前 5/12 首选、9/12 前五、11/12 候选集内
  .venv\Scripts\python.exe .local\regress_after_fix.py   # 70 样本无非 ASCII、耗时无退化
  .venv\Scripts\python.exe .local\e2e_candidates.py      # 在空闲端口起服务走真实 HTTP，端到端复核
  ```

  `regress_after_fix.py` 把当前实现与 `.local/_old_server.py` 对比，后者是所有优化之前的原版快照（保留它是为了能随时验证「改了这么多之后字母识别没退化」）。它报告的「不同 33/70」是预期的，那些差异全部只在大小写上；真正要盯的是「含非 ASCII 应为 0」和耗时。

  `e2e_candidates.py` 特意用空闲端口（17905），不要改成 17898。新服务会因排他绑定直接拒绝；如果 17898 上还是未重启的旧实例，测试服务仍可能因 `SO_REUSEADDR` 命中错误进程。
- Windows 上 `.ps1` **必须带 UTF-8 BOM**。没有 BOM 时 PowerShell 5.1 按 ANSI(GBK) 解码，中文注释处解析就会乱，导致 `. 公共-查找Python.ps1` 静默失效、报「Resolve-PythonRuntime 不是可识别的 cmdlet」。这个坑只在 `-File` 模式暴露，`-Command` 模式测不出来。
- 不要在启动脚本里内联 Python 解析逻辑。必须 dot-source `公共-查找Python.ps1` —— 它把项目 `.venv` 排在第一候选并校验 3.10+，内联版两者都会丢，后果是依赖装在 `.venv`、服务却用系统 Python。

## 识别流程

改代码前先理解这条链路，它不是「一个模型输出答案」，而是**三个引擎各提供不同信号，再拼出候选列表**。

```
图片
 ├─ ddddocr default ──┐
 ├─ ddddocr beta ─────┼─→ 字母身份(是哪几个字母)
 └─ split_boxes()     │
     ├─ 整行裁剪 ─────┤
     └─ 4 个字符裁剪 ─┴─→ 大小写信号(每位的置信度)
                          ↓
                    enhanced_candidate()  ← 逐位还原大小写
                          ↓
                    order_variants()      ← 枚举大小写变体并排序
                          ↓
                    candidates[]          ← 返回给调用方
```

关键点：

- **`split_boxes()` 用纯 numpy 定位字符**，不用神经网络检测。验证码上除字符没有别的墨迹，所以按 x 轴做 k-means 聚成 4 类即可，约 1ms。
- **字母身份主要来自 ddddocr**，两个模型（default / beta）互为参照。
- **大小写信号只能来自逐字符裁剪**。整行识别器会把行高归一化，导致它对同形字母输出的大小写不携带信息（详见「已知问题」）。
- **`order_variants()` 决定成功率**。因为首选答案只有 5/12 正确，但候选集内有 11/12，排序好坏直接决定调用方要试几次。当前策略：按与首选的汉明距离升序，同距离内按「翻转代价」升序（优先翻转 crop 证据最弱的位）。排序**只依赖每张图自己的证据**，不引入拿少量标注拟合的全局先验——这是有意的，全局先验在 12 张的样本量上极易过拟合。

## 性能背景

### 先读这条：本节数字不是可复现基准

**同一份代码、同一台 8 核机器，实测过 75ms、88ms、104ms、185ms。** 最极端的一次是 `spin_test.py` 用完全相同的参数连续跑两遍，得到 75.0ms 和 178.9ms。

原因是后台负载：本机有 CCleaner 服务等进程在跑，压测时抢核。所以：

- **要报数就现测一遍**，别引用本文档的绝对值：
  ```powershell
  .venv\Scripts\python.exe .local\bench_one.py ocr\exmail_captcha_ocr_server.py
  ```
- **不要跨脚本比较绝对值**。`spin_test.py` 与 `bench_one.py` 对同一份代码可能报 75ms 和 185ms，因为预热次数和测量口径不同。只在同一脚本的一次运行内做 A/B 才有意义。
- 判断某项优化是否有效，看**相对关系是否稳定复现**，而不是看单次数字。下面每条都注明了复现方法。

最近一次 `bench_one.py` 实测 mean 185–199ms（三次连测）；最初完全未优化的版本约 1295ms。关键改动：

- **跳过 RapidOCR 的 DBNet 检测阶段**。它是最大的一笔开销（实测 370–480ms，占当时总耗时的大头），因为会把 130×53 的图放大到 736px 最小边再检测。而验证码上除字符没有别的墨迹，`split_boxes()` 用纯 numpy 约 1ms 就能定位。

  检测不但贵，**覆盖率还更差**：70 样本里它有 24 个完全找不到文字（46/70 有输出），而直接把墨迹外接框喂给识别器能读出 61/70。找不到文字就意味着大小写还原拿不到信号。用 `.local/det_free2.py` 可复现这个对比。
- **关掉 ONNX Runtime 的 intra-op 自旋等待**（`session.intra_op.allow_spinning=0`）。每请求跑三个 session，一个推理时另两个的 worker 线程会空转抢核。

  **输出逐字节不变**（已两次验证），所以关掉它没有正确性风险。但提速幅度**不可靠复现**：测过 121ms→73ms（约 40%），也测过 183.6ms→178.9ms（约 2.5%）。差异来自机器后台负载（本机有 CCleaner 服务等在跑）。保守的说法是「无风险、有时明显有效」,不要把 40% 当成可承诺的收益。
- **线程数设 4**（不是全部逻辑核）。8 核机器上实测 1/2/4/8 线程分别 142/89/75/151ms —— 4 线程最优，用满 8 核反而**慢一倍**，因为张量很小，线程同步开销超过并行收益。这个相对关系可稳定复现，用 `.local/spin_test.py` 验证：

  ```powershell
  $env:SPIN=0; $env:THREADS=4; .venv\Scripts\python.exe .local\spin_test.py
  ```
- 三个 session 并发跑；启动时预热（预热图必须有四列墨迹，否则 `split_boxes` 找不到框、最贵的识别 session 仍是冷的）。

## 已知问题与陷阱

- **对比度兜底只在主引擎凑不出 4 位时触发，不要改成默认开启**。删除线和空心描边会让首字符笔画淡到主引擎漏读（输出只剩 3 位、候选集直接为空）。提高对比度能救回，但实测 70 样本中无条件启用会让 5 张原本正确的退化成 3 位（增强也会把相邻字符笔画连到一起），只有 2 张改善，净负。
- **同形字母的大小写判据是脆的**。`cosuvwxzpkmnyj` 大小写字形基本相同，只能靠相对高度区分，而整行识别器会把行高归一化掉——它对这些字母输出的大小写不携带信息，只反映模型自身的全大写倾向。现在靠逐字符 crop 置信度阈值 `0.60` 判定，但**这个阈值是拟合当前分割方式的**：换成按墨迹投影谷底切分后，`live_06` 首字母置信度会从 0.540 漂到 0.616，越过阈值产生误大写。
- **三种几何判据实测全部不可用**。相对行高、相对最高框、绝对像素高度都有重叠（最好情况错分 6/22）。原因是全小写或全大写的图里没有参照物（`pgbp`、`ynyn` 的最高框本身就是小写字母），加上 p/y/g/j 的降部让小写框高追平大写。
- **`live_10` 未解决**：真值 `NEDG`，三个引擎一致读成 `nEBG`，B↔D 混淆。三引擎一致犯错说明加权投票救不了，需要换模型或专门训练。
- **真值集只有 12 张、21 个同形字母位置**，样本量小，所有比例的置信区间都很宽。对外引用这些数字前建议先扩充标注。

## 真值集与如何扩充

`.local/live/human.txt` 是**人工逐张读图标注**的，制表符分隔：

```
live_01.png	mGNS
live_03.png	MHMY	ambiguous
```

第三列 `ambiguous` 表示标注时也难以断定（目前 3 张有此标记），评测脚本会把它单独统计出来，便于判断某次失败是模型问题还是题目本身模糊。

**扩充流程**：

```powershell
# 1. 抓新验证码。它同时会存原图 live_NN.png 和放大 6 倍的 big_live_NN.png
#    （130x53 原图很难读准大小写，放大版是给人看的）
$env:COUNT=12; .venv\Scripts\python.exe .local\live_test.py

# 2. 逐张读 .local/live/big_live_*.png，把结果追加进 .local/live/human.txt
```

（`.local/upscale.py` 是另一套用途：它只放大 `.local/samples/cap_*.png` 那 70 张无标注样本，与真值集无关。）

**标注要点**（这些是实际踩过的坑）：

- 大小写靠**相对高度**判断：同形字母（`cosuvwxzpkmnyj`）的大小写字形一样，只能看它相对同图其他字符的高低。
- `b d f h k l t` 有上升部、`g j p q y` 有下降部，即使小写也很高，别只看绝对高度。
- 图上有一条干扰删除线，忽略它。
- 拿不准就标 `ambiguous`,不要猜——错误的真值比缺失的真值危害大得多。

**已知陷阱**：`live_test.py` 把 `OUTDIR` 写死为 `.local/live`,从不清空，且 `answers.txt` 用 `"w"` 模式截断。所以跑一次 `COUNT=5` 会把上一轮 12 张的记录冲掉，只留 5 行，而 12 张图还在目录里——看起来像「丢了 7 行」,其实是新旧两轮混在一个目录。判断某张图属于哪一轮要比对 mtime。扩充标注前建议先清空 `.local/live` 或改用别的目录。

## 调研过的开源方案（都不可用）

| 方案 | 在本项目真值集上实测 |
|------|---------------------|
| [xiaolv/ocr-captcha](https://huggingface.co/xiaolv/ocr-captcha) small | 1/12 |
| 同上 big | 0/12 |
| 现有 ddddocr + RapidOCR 集成 | 5/12 严格 / 11/12 忽略大小写 |

两个 HuggingFace 模型输出全小写、字符数在 3~5 之间不稳。它们是 804×32 宽幅行识别器，130×53 的图被拉伸到宽高比 25:1 严重失真；训练数据是「常见验证码」，没见过 exmail 的删除线+字符粘连+空心描边字形。README 声称的「精度接近 100%」在本项目数据上不成立。所以「用它自动标注再训专用模型」也不可行——会把它的错误当标签学进去。

[bojone/n2n-ocr-for-qqcaptcha](https://github.com/bojone/n2n-ocr-for-qqcaptcha) 是旧版 QQ 验证码、仅 26 个小写类、无预训练权重、Keras 1.x/Python 2。

[sml2h3/dddd_trainer](https://github.com/sml2h3/dddd_trainer) 技术上可行：已确认 `ddddocr.DdddOcr` 支持 `import_onnx_path` / `charsets_path`，训练产物能零新增依赖插进现有服务。瓶颈是需要几千张人工标注。
