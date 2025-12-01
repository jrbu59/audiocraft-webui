from .model_hijack import HijackedMusicGen
from audiocraft.data.audio import audio_write
import torch, re, os, json, unicodedata, hashlib, random

MODEL = None

def load_model(version, socketio):
    global MODEL
    print("Loading model", version)
    try:
        MODEL = HijackedMusicGen.get_pretrained(socketio, version)
    except Exception as e:
        print(f"Failed to load model due to error: {e}, you probably need to pick a smaller model.")
        torch.cuda.empty_cache()
        torch.cuda.synchronize()
        return None
    return MODEL

def sanitize_filename(filename: str, max_length: int = 80) -> str:
    """将任意提示词转为安全的短文件名。

    处理策略：
    - 归一化并移除非 ASCII 字符（避免多字节导致的 255 字节组件超限）。
    - 仅保留字母、数字、空格、下划线、连字符。
    - 压缩连续空白为单个空格，并裁剪首尾空白。
    - 裁剪总长度到 max_length；若为空则回退为 'audio'.
    """
    if not isinstance(filename, str):
        filename = str(filename)
    # 归一化并移除非 ASCII 字符
    normalized = unicodedata.normalize('NFKD', filename)
    ascii_only = normalized.encode('ascii', 'ignore').decode('ascii')
    # 只保留安全字符
    ascii_only = re.sub(r'[^A-Za-z0-9_\-\s]', ' ', ascii_only)
    # 压缩空白
    ascii_only = re.sub(r'\s+', ' ', ascii_only).strip()
    # 裁剪长度
    if len(ascii_only) > max_length:
        ascii_only = ascii_only[:max_length].rstrip()
    # 回退名：若全为非 ASCII，使用短哈希保证可区分
    if not ascii_only:
        short_hash = hashlib.sha1(filename.encode('utf-8')).hexdigest()[:8]
        return f"audio-{short_hash}"
    return ascii_only

def write_paired_json(model_type, filename, prompt, audio_gen_params):
    output_filename = f"{filename}.json"

    import time as _time
    write_data = {
        "model": model_type,
        "prompt": prompt,
        "parameters": audio_gen_params,
        "generated_at": _time.strftime('%Y-%m-%d %H:%M:%S')
    }

    with open(output_filename, 'w', encoding='utf-8') as outfile:
        json.dump(write_data, outfile, indent=4, ensure_ascii=False)

    return output_filename

def write_audio(model_type, prompt, audio, audio_gen_params):
    global MODEL
    base_dir = "static/audio"
    # 生成短而安全的文件名基名（不含扩展名）
    slug = sanitize_filename(prompt, max_length=80)
    base_filename = os.path.join(base_dir, slug)
    output_filename = f"{base_filename}.wav"

    audio_tensors = audio.detach().cpu().float()
    sample_rate = MODEL.sample_rate

    # 自动去重：同名则追加 (i)
    i = 1
    while os.path.exists(output_filename):
        output_filename = f"{base_filename}({i}).wav"
        i += 1

    # 应用淡入淡出
    fade_ms = int(float(audio_gen_params.get('fade_ms', 0) or 0))
    wav = audio_tensors.squeeze()
    if fade_ms and fade_ms > 0:
        n = int(sample_rate * (fade_ms / 1000.0))
        if n > 0 and wav.numel() > 2 * n:
            # 线性淡入淡出
            import torch as _torch
            ramp = _torch.linspace(0, 1, steps=n)
            wav[:n] = wav[:n] * ramp
            wav[-n:] = wav[-n:] * ramp.flip(0)

    # 写文件（响度处理可调）
    audio_write(
        output_filename,
        wav,
        sample_rate,
        strategy="loudness",
        loudness_headroom_db=float(audio_gen_params.get('loudness_headroom_db', 18)),
        loudness_compressor=True,
        add_suffix=False,
    )

    # 可选重采样到 44.1kHz：生成完成后使用 torchaudio 重采样
    try:
        import torchaudio as _ta
        if bool(audio_gen_params.get('resample_44k', False)):
            resample_sr = 44100
            resampled = _ta.functional.resample(wav.unsqueeze(0), sample_rate, resample_sr)
            # 覆盖原文件为 44.1kHz
            audio_write(
                output_filename,
                resampled.squeeze(0),
                resample_sr,
                strategy="loudness",
                loudness_headroom_db=float(audio_gen_params.get('loudness_headroom_db', 18)),
                loudness_compressor=True,
                add_suffix=False,
            )
    except Exception:
        pass

    json_filename = write_paired_json(
        model_type,
        output_filename.rsplit('.', 1)[0],
        prompt,
        audio_gen_params,
    )

    return output_filename, json_filename

def generate_audio(socketio, model_type, prompt, audio_gen_params, melody_data):
    global MODEL
    if not MODEL or MODEL.name != f"facebook/musicgen-{model_type}":
        load_model(model_type, socketio)
    if not MODEL:
        print("Couldn't load model.")
        return
    
    params = dict(audio_gen_params)
    # 默认随机种子逻辑：仅在高级设置传递了 seed 键时处理
    if 'seed' in params:
        seed_val = params.get('seed')
        if seed_val in (None, '', 'null'):
            # 生成一个随机种子并记录到参数中，便于复现与历史查看
            params['seed'] = random.randint(0, 2**31 - 1)
    # 提取受支持的生成参数
    gen_kwargs = {
        'use_sampling': True,
        'top_k': int(params.get('top_k', 250)) if params.get('top_k') is not None else None,
        'top_p': float(params.get('top_p', 0.67)) if params.get('top_p') is not None else None,
        'temperature': float(params.get('temperature', 1.2)) if params.get('temperature') is not None else None,
        'cfg_coef': float(params.get('cfg_coef', 4.0)) if params.get('cfg_coef') is not None else None,
        'duration': int(float(params.get('duration', 30))) if params.get('duration') is not None else None,
        # 高级设置：仅当键存在才生效（前端折叠时不传）
        'two_step_cfg': bool(params['two_step_cfg']) if 'two_step_cfg' in params else None,
    }
    # 清理 None，避免覆盖默认
    gen_kwargs = {k: v for k, v in gen_kwargs.items() if v is not None}
    MODEL.set_generation_params(**gen_kwargs)

    # 设定随机种子（若提供），而不是传入 set_generation_params
    if 'seed' in params:
        s = int(params['seed'])
        try:
            torch.manual_seed(s)
            torch.cuda.manual_seed_all(s)
        except Exception:
            # CPU-only 情况
            torch.manual_seed(s)
        try:
            import numpy as _np
            _np.random.seed(s)
        except Exception:
            pass
        random.seed(s)
    
    if melody_data is not None:
        melody, melody_sr = melody_data
        output = MODEL.generate_with_chroma(
            descriptions=[prompt],
            melody_wavs=melody,
            melody_sample_rate=melody_sr,
            progress=True
        )
    else:
        output = MODEL.generate(descriptions=[prompt], progress=True)
    
    # 将可能更新过的参数（含随机种子）写入配对 JSON
    return write_audio(model_type, prompt, output, params)
