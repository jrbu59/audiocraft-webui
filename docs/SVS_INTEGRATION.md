# 歌词+旋律人声合成（SVS）集成方案

本文档给出在当前 audiocraft WebUI 中集成“歌词+旋律→人声（Singing Voice Synthesis, SVS）”的详细方案，涵盖目标与范围、资源筹备、架构设计、接口与数据结构、后端处理流程、测试与里程碑、维护与扩展。

## 1. 目标与范围
- 目标：在现有 WebUI 中新增人声合成能力，使用户能输入“歌词 + 旋律（MIDI/音高曲线/参考旋律音频）”，生成歌唱人声，并可与伴奏（MusicGen）混音。
- 范围：
  - 前端：新增“人声”页或折叠面板（SVS），支持歌词、旋律、歌手、语言与若干控制参数。
  - 后端：新增 `mechanisms/svs_backend.py`，统一封装对开源 SVS 模型（优先 DiffSinger，兼容 NNSVS）的推理调用与文件写入逻辑。
  - 存储：输出人声 WAV 与参数 JSON，遵循现有命名与配对规则，并支持与伴奏混音输出。

## 2. 资源与环境准备
- 软件与库：
  - Python 3.10（与现有项目一致），PyTorch（与 audiocraft/MusicGen 兼容的版本），`torchaudio`。
  - 音频工具：`librosa`（时域/频域处理与音高曲线）、`numpy`、`soundfile` 或使用 `torchaudio.save`。
  - 可选混音：`pydub` 或使用 `torchaudio` 的张量混合（推荐后者，减少依赖）。
  - 若未来生产化：可考虑 `eventlet/gevent` 以提升 WebSocket 并发，但当前以研究为主可暂不引入。

- 模型与声库（离线资源，需手动下载/准备）：
  - DiffSinger：
    - 预训练声库（多语言/多歌手）。包含模型权重、音素词典、配置文件、（可选）前处理字典。
    - 资源放置建议：`models/svs/diffsinger/<singer_id>/` 下放置 `model.pth`、`config.yaml`、`phoneme_dict.txt` 等。
  - NNSVS（如需日语或特定音色）：对应 `models/svs/nnsvs/<singer_id>/`。
  - 版权与许可：确保所用声库与数据集符合许可，避免上传至仓库。

- 硬件要求：
  - GPU：建议使用带 CUDA 的 GPU（>= 8GB），以获得更快的推理速度。CPU 亦可但耗时较长。
  - 存储：SVS 声库与模型权重可能较大（数百 MB 至数 GB）。

- 路径与命名（与项目规范一致）：
  - 输出目录：`static/audio/`，文件名由提示词/歌词生成，使用 `sanitize_filename` 自动去重，如 `static/audio/my_song(2).wav`。
  - 参数 JSON：与 WAV 同名，如 `static/audio/my_song.json`，记录模型、歌手、语言、旋律来源与关键参数。

## 3. 用户流程（前端交互）
1. 进入 WebUI，切换到“人声（SVS）”面板。
2. 填写：
   - 歌词（多行文本框 `lyricsText`），支持中/英；
   - 旋律：
     - 上传 MIDI（`midiFile`），或
     - 上传参考旋律音频（`melodyFile`），后端提取音高曲线；
     - 或直接使用 Pitch 曲线 JSON（`pitchCurveFile`）。
   - 模型与歌手（下拉 `singerId`）、语言（`language`）。
   - 可选参数：`tempo`、`pitchShift`、`formantShift`、`reverbMix`、`vocalGain`、`fadeMs`、`resample44k` 等。
3. 点击“生成人声”，前端通过 SocketIO 发送 `svs_submit` 事件，后端入队处理。
4. 生成完成后，后端通过 `on_finish_audio` 事件返回文件名与耗时，列表更新并提供试听与下载。
5. 若勾选“与伴奏混音”，在生成后自动尝试与最近一次 MusicGen 伴奏或指定伴奏文件混音并输出混合轨。

## 4. 架构与模块设计
- 前端（`templates/index.html` + `static/main.js`）：
  - 新增 SVS 面板（表单控件 ID 与后端键名一致，遵循 camelCase）。
  - 事件：
    - 上传 MIDI：`POST /upload_midi`，返回本地路径；
    - 上传参考旋律：沿用或复用现有 `POST /upload_melody`；
    - 提交生成：通过 `socket.emit('svs_submit', payload)`。

- 后端（`webui.py` + `mechanisms/svs_backend.py`）：
  - `webui.py`：
    - 新增 SocketIO 事件处理器：`@socketio.on('svs_submit')`，校验参数，组装任务并入队。
    - 新增上传路由：`/upload_midi`（保存至 `static/temp/`）。
    - 统一输出事件与错误事件：与现有 `generate_audio` 一致的 `status`/`on_finish_audio`/`gen_error`。
  - `mechanisms/svs_backend.py`：
    - 函数：`generate_vocal(socketio, lyrics, melody, controls, singer_cfg)`。
    - 职责：
      - 预处理：歌词正则化、分词/音素化（根据语言选择字典），若为参考旋律则提取音高曲线（`librosa.pyin` 或 `torchaudio`），或读取 MIDI（`mido`）。
      - 推理封装：调用 DiffSinger/NNSVS 推理接口，生成人声波形（`torch.Tensor` 或 `np.ndarray`）。
      - 后处理：响度与淡入淡出、可选重采样至 44.1kHz，保存 WAV。
      - 参数 JSON：记录输入与控制参数，返回 `(wav_filename, json_filename)`。
    - 抽象：
      - `class SVSEngine`，实现 `prepare()`, `infer()`, `postprocess()`；
      - `DiffSingerEngine`/`NNSVSEngine` 具体类，支持多歌手/多语言切换。

- 队列与线程：沿用 `pending_queue`，任务结构增加 `job_type` 字段：`{"type":"svs", ...}`，后端线程根据类型路由至相应后端模块。

## 5. 接口与数据结构（示例）
- SocketIO 入队事件：
```json
{
  "type": "svs",
  "lyrics": "今夜星光灿烂...",
  "melody": {
    "type": "midi", // 或 "audio" / "pitch_curve"
    "path": "static/temp/example.mid"
  },
  "controls": {
    "tempo": 120,
    "pitchShift": 0,
    "formantShift": 0.0,
    "reverbMix": 0.2,
    "vocalGain": 0.0,
    "fadeMs": 100,
    "resample44k": true
  },
  "singer": {
    "engine": "diffsinger",
    "singerId": "cn_female_001",
    "language": "zh"
  }
}
```

- 输出 JSON（与 WAV 同名）：
```json
{
  "type": "svs",
  "engine": "diffsinger",
  "singerId": "cn_female_001",
  "language": "zh",
  "lyrics": "今夜星光灿烂...",
  "melody": {"type": "midi", "path": "static/temp/example.mid"},
  "controls": {"tempo":120, "pitchShift":0, "formantShift":0.0, "reverbMix":0.2, "fadeMs":100, "resample44k":true},
  "elapsed": 12.34
}
```

## 6. 后端处理流程（详细）
1. 参数校验与规范化：
   - `lyrics` 必填（去除空行，统一标点）；`melody` 必填其一（MIDI/音频/曲线）；
   - 路径限制在 `static/temp/`；超出路径立即报错并返回 `gen_error`。
2. 旋律解析：
   - MIDI：用 `mido` 解析音符事件，构建时间-音高曲线；
   - 音频：用 `librosa.pyin` 或 `librosa.yin` 提取 F0 与有声/无声掩码；
   - Pitch 曲线 JSON：直接读取为时间序列；
   - `tempo` 与单位转换（秒/拍）统一。
3. 歌词→音素：
   - 中文：分词与拼音，拼音→音素（使用随声库提供的字典）；
   - 英文：G2P（可选 `g2p_en`，或随声库字典）。
4. 推理：
   - 准备：加载 `singerId` 对应权重与配置，放至 GPU；
   - 调用 `SVSEngine.infer(phonemes, f0_curve, tempo, controls)`，输出波形；
5. 后处理：
   - 响度头间（`loudness_headroom_db` 类似已有参数可复用）、淡入淡出（`fadeMs`）、可选重采样至 44.1kHz（`resample44k`）。
6. 保存与事件：
   - 命名：由 `lyrics` 派生，`sanitize_filename` 去重，写入 `static/audio/`；
   - 事件：`on_finish_audio` 包含文件名与耗时；失败时 `gen_error` 简短提示。
7. 可选混音：
   - 若提供伴奏路径或自动取最新伴奏：读取两轨至张量，按 `vocalGain`、`reverbMix` 等进行简单混合并另存一份 `*_mix.wav`（额外 JSON 标记 `mix_of: [vocal_wav, backing_wav]`）。

## 7. 前端改动（概要）
- `templates/index.html`：新增 SVS 面板，包含：
  - 文本域 `id="lyricsText"`；文件上传 `id="midiFile"` 与 `id="melodyFile"`；
  - 选择控件：`id="singerId"`, `id="language"`；
  - 滑块：`id="tempo"`, `id="pitchShift"`, `id="formantShift"`, `id="reverbMix"`, `id="vocalGain"`, `id="fadeMs"`, `id="resample_44k"`；
  - 按钮：`id="submitSVS"`。
- `static/main.js`：
  - 绑定上传路由 `/upload_midi`、复用 `/upload_melody`；
  - 组装并发送 `svs_submit`；接收 `status` 与 `on_finish_audio` 更新 UI。

## 8. 依赖与安装（建议）
- `requirements.txt` 可能新增：`librosa`, `mido`, （可选）`g2p_en`, `pydub`。
- 模型不随仓库分发，需用户将声库资源放至 `models/svs/...`，并在 UI 选择或通过配置自动发现。

## 9. 错误处理与健壮性
- 路径白名单：仅允许 `static/temp/`；对越权路径立即拒绝。
- 资源缺失：模型/声库未找到时给出明确提示并引导路径；
- 推理超时：对单次任务设定最大时长（例如 300s），超时回收并提示；
- 并发：沿用队列，防止多个 SVS 任务抢占同一声库资源；必要时加锁。

## 10. 测试计划
- 单元测试（建议补充于 `mechanisms/`）：
  - 参数转换与音素化；MIDI→音高曲线；音频提取 F0；
  - 文件写入命名与 JSON 字段完整性；
  - 混音结果采样率与峰值范围。
- 手动测试：
  - UI 提交样例歌词与 MIDI/音频；观察队列事件与生成结果；
  - 检查 `static/audio/` 是否生成两类（人声与混音）WAV 与配对 JSON。

## 11. 里程碑与分工（示例）
1. M1：最小可用（不接入真实模型）
   - 前端面板与路由；后端 `svs_backend.py` 生成占位音（如正弦）；打通端到端。
2. M2：接入 DiffSinger
   - 加载声库；实现歌词→音素与 MIDI/F0；人声输出；参数 JSON；
3. M3：混音与体验优化
   - 与伴奏混音；响度与淡入淡出；错误提示完善；
4. M4：稳定性与文档
   - 增补测试；记录完整资源准备与操作说明；

## 12. 安全与合规
- 不提交 `models/`、`settings/`、生成音频到仓库（遵循 `.gitignore`）。
- 声库版权与许可需用户自检；文档中不嵌入受限资源链接。

## 13. 维护与扩展
- Singer/语言可通过 `models/svs/` 目录扫描自动填充下拉；
- 支持多引擎（DiffSinger/NNSVS），通过统一接口兼容；
- 后续可加入“歌词自动分词/G2P”按钮与参考人声风格迁移等拓展功能。

---

附：集成最小改动清单（开发指引）
1. 新增文件：`mechanisms/svs_backend.py`（占位实现，后续接入 DiffSinger）。
2. `webui.py`：
   - 新增 SocketIO 事件 `svs_submit` 与路由 `/upload_midi`；
   - 在线程中根据 `job_type` 分发至 `generate_vocal`；
3. 前端：新增 SVS 面板与对应 JS 逻辑。
4. `requirements.txt`：按需补充 `librosa`, `mido`（以及可选组件）。

