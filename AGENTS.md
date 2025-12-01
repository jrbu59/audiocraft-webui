# Repository Guidelines

## 项目结构与模块组织
- 入口：`webui.py`（Flask + SocketIO，后台队列处理音频生成）。
- 后端：`mechanisms/`（`generator_backend.py` 负责生成与写文件；`model_hijack.py` 注入进度回调）。
- 前端：`templates/index.html` 与 `static/`（`main.js`、样式、输出音频与配对 JSON）。
- 运行数据：`static/audio/`、`static/temp/`、`settings/last_run.json`（已在 `.gitignore` 中忽略）。

## 构建、测试与开发命令
- 安装依赖：`bash install.sh` 或 `bash install.sh --conda`（创建 Python 3.10 环境并安装 `requirements.txt`）。
- 本地运行：`bash run.sh`（激活环境并启动服务）或 `python webui.py`。
- 生成结果：音频与参数 JSON 位于 `static/audio/`；上传旋律缓存位于 `static/temp/`。

## 编码风格与命名约定
- Python：遵循 PEP 8，4 空格缩进；模块/函数/变量使用 `snake_case`。
- JavaScript：使用 `camelCase`；模板与脚本的控件 `id` 与后端键名一致（如 `top_k`、`temperature`）。
- 文件命名：由提示词生成，使用 `sanitize_filename` 清理并自动去重（示例：`static/audio/hello(2).wav`）。

## 测试指南
- 现阶段以手动测试为主：
  - 启动服务后在 UI 提交示例提示词，观察进度事件与队列变化。
  - 检查 `static/audio/` 是否生成 `.wav` 与配对 `.json`，参数字段正确。
- 建议补充单元测试（针对 `mechanisms/` 的参数设置与文件写入逻辑）。

## 提交与拉取请求指南
- 提交信息：保持简洁、祈使语气、说明范围（示例：`Fix: ordering bug in audio list`、`Add: reload last run settings`）。
- PR 要求：提供清晰描述与关联 Issue、复现步骤；前端改动附截图/录屏；说明影响的目录与脚本命令。

## 安全与配置提示（可选）
- 使用独立虚拟环境（或 Conda），不要提交 `venv/`、`settings/`、生成音频至仓库。
- 安装 `audiocraft` 依赖需要网络；GPU 资源有限时选择较小模型（`small`/`medium`）。
