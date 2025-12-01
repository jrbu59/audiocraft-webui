from flask_socketio import SocketIO, emit
from flask import Flask, render_template, request, jsonify, send_from_directory
import logging, os, queue, threading, json
from urllib.parse import urlparse
import torchaudio
from mechanisms.generator_backend import generate_audio

app = Flask(__name__)
pending_queue = queue.Queue()
socketio = SocketIO(app, cors_allowed_origins="*")
logging.getLogger().setLevel(logging.ERROR)
logging.getLogger('engineio').setLevel(logging.ERROR)
logging.getLogger('socketio').setLevel(logging.ERROR)

def worker_process_queue():
    while True:
        model_type, prompt, slider_data, melody_data = pending_queue.get()
        try:
            socketio.emit('status', {"prompt": prompt, "state": "started"})
            filename, json_filename = generate_audio(socketio, model_type, prompt, slider_data, melody_data)
            socketio.emit('on_finish_audio', {"prompt": prompt, "filename": filename, "json_filename": json_filename})
            socketio.emit('status', {"prompt": prompt, "state": "finished"})
        except Exception as e:
            # 简短错误提示
            socketio.emit('error', {"prompt": prompt, "message": str(e)[:200]})
            socketio.emit('status', {"prompt": prompt, "state": "error"})
        finally:
            pending_queue.task_done()
        
def save_last_gen_settings(model_type, prompt, audio_gen_params):
    os.makedirs("settings", exist_ok=True)
    output_filename = "settings/last_run.json"
    write_data = {"model":model_type, "prompt":prompt, "parameters":audio_gen_params}
    
    with open(output_filename, 'w') as outfile:
        json.dump(write_data, outfile, indent=4)
        
def load_last_gen_settings():
    input_filename = "settings/last_run.json"
    if not os.path.exists(input_filename):
        return None, None, None
    
    with open(input_filename, 'r') as infile:
        settings = json.load(infile)
        model = settings["model"]
        prompt = settings["prompt"]
        topp = float(settings["parameters"]["top_p"])
        duration = int(settings["parameters"]["duration"])
        cfg_coef = float(settings["parameters"]["cfg_coef"])
        topk = int(settings["parameters"]["top_k"])
        temperature = float(settings["parameters"]["temperature"])
        return model, prompt, topp, duration, cfg_coef, topk, temperature
    
    
@socketio.on('submit_sliders')
def handle_submit_sliders(json):
    slider_data = json['values']
    prompt = json['prompt']
    model_type = json['model']
    if not prompt:
        return
    
    # 将滑块参数转换为合适类型
    typed_slider_data = {}
    for key, value in slider_data.items():
        if key in ('top_p', 'temperature', 'cfg_coef'):
            typed_slider_data[key] = float(value)
        elif key in ('duration', 'top_k'):
            typed_slider_data[key] = int(float(value))
        elif key == 'two_step_cfg':
            typed_slider_data[key] = bool(int(value))
        elif key == 'seed':
            typed_slider_data[key] = int(value) if value is not None else None
        elif key == 'loudness_headroom_db':
            typed_slider_data[key] = float(value)
        elif key == 'fade_ms':
            typed_slider_data[key] = int(float(value))
        elif key == 'resample_44k':
            typed_slider_data[key] = bool(int(value))
        else:
            # 兜底为 float
            try:
                typed_slider_data[key] = float(value)
            except:
                typed_slider_data[key] = value
    
    melody_data = None
    
    melody_url = json.get('melodyUrl', None)
    # Melody 模式后端校验：必须有有效文件
    if model_type == 'melody':
        if not melody_url:
            socketio.emit('error', {"prompt": prompt, "message": "请先上传旋律音频"})
            return
        # 将 URL 转成本地相对路径并限制到 static/temp 目录
        parsed = urlparse(melody_url)
        local_path = parsed.path.lstrip('/') if parsed.scheme else melody_url
        if not local_path.startswith('static/temp/'):
            socketio.emit('error', {"prompt": prompt, "message": "旋律路径不合法"})
            return
        if not os.path.exists(local_path):
            socketio.emit('error', {"prompt": prompt, "message": "旋律文件不存在"})
            return
        melody_data = torchaudio.load(local_path)

    save_last_gen_settings(model_type, prompt, typed_slider_data)
    socketio.emit('add_to_queue', {"prompt": prompt})
    pending_queue.put((model_type, prompt, typed_slider_data, melody_data))
    
@socketio.on('connect')
def handle_connect():
    audio_json_pairs = get_audio_json_pairs("static/audio")
    socketio.emit('audio_json_pairs', audio_json_pairs)
    
def get_audio_json_pairs(directory):
    files = os.listdir(directory)
    wav_files = [f for f in files if f.endswith('.wav')]
    json_files = [f for f in files if f.endswith('.json')]
    
    pairs = []
    for wav_file in wav_files:
        base_name = os.path.splitext(wav_file)[0]
        json_file = f"{base_name}.json"
        if json_file in json_files:
            full_wav_path = os.path.join(directory, wav_file)
            full_json_path = os.path.join(directory, json_file)
            pairs.append((full_wav_path, full_json_path))
            
    pairs.sort(key=lambda pair: os.path.getmtime(pair[0]), reverse=True)
    return pairs
    
@app.route('/upload_melody', methods=['POST'])
def upload_audio():
    dir = "static/temp"
    for filename in os.listdir(dir):
        file_path = os.path.join(dir, filename)
        if os.path.isfile(file_path) or os.path.islink(file_path):
            os.unlink(file_path)
            
    if 'melody' not in request.files:
        return jsonify({'error': 'No file part'}), 400
    file = request.files['melody']
    if not file or file.filename == '':
        return jsonify({'error': 'No selected file'}), 400
    if file.content_type.startswith('audio/'):
        filename = file.filename
        file_path = os.path.join(dir, filename)
        file.save(file_path)
        return jsonify({'filePath': file_path}), 200

@app.route('/')
def index():
    try:
        model, prompt, topp, duration, cfg_coef, topk, temperature = load_last_gen_settings()
        if model is not None:
            return render_template('index.html', 
                                topk=topk, 
                                duration=duration, 
                                cfg_coef=cfg_coef, 
                                topp=topp, 
                                temperature=temperature, 
                                default_model=model,
                                default_text=prompt)
    except:
        pass
    
    topk = 250
    duration = 30
    cfg_coef = 4.0
    topp = .67
    temperature = 1.2
    default_model = "large"
    default_text = ""
    default_seed = 123456
    return render_template('index.html', 
                           topk=topk, 
                           duration=duration, 
                           cfg_coef=cfg_coef, 
                           topp=topp, 
                           temperature=temperature, 
                           default_model=default_model,
                           default_text=default_text,
                           default_seed=default_seed)

if __name__ == '__main__':
    if not os.path.exists('static/audio'):
        os.makedirs('static/audio')
    if not os.path.exists('static/temp'):
        os.makedirs('static/temp')
    threading.Thread(target=worker_process_queue, daemon=True).start()
    socketio.run(app, host='0.0.0.0')
