var socket = io.connect('http://' + document.domain + ':' + location.port);

// SLIDERS

document.addEventListener("DOMContentLoaded", function() {
    document.querySelectorAll('input[type="range"]').forEach(function(slider) {
        updateSliderValue(slider.id, slider.value);
    });
    initModes();
    initParamHints();
    initAdvancedPanel();
});

function submitSliders() {
    var slidersData = {};
    var textData = document.getElementById('text').value;

    // 读取当前模式
    var isMelodyMode = document.getElementById('mode-melody').classList.contains('active');

    // 收集滑块
    document.querySelectorAll('input[type="range"]').forEach(function(slider) {
        slidersData[slider.id] = slider.value;
    });
    // 是否启用高级设置（面板展开时生效）
    const useAdvanced = !document.getElementById('advanced-panel').classList.contains('collapsed');
    if (useAdvanced){
        slidersData['two_step_cfg'] = document.getElementById('two_step_cfg').checked ? 1 : 0;
        const seedFixed = document.getElementById('seed-fixed').checked;
        const seedVal = document.getElementById('seed').value;
        slidersData['seed'] = seedFixed && seedVal !== '' ? parseInt(seedVal, 10) : null;
        slidersData['loudness_headroom_db'] = parseFloat(document.getElementById('loudness_headroom_db-text').value || '18');
        slidersData['fade_ms'] = parseInt(document.getElementById('fade_ms-text').value || '60', 10);
        slidersData['resample_44k'] = document.getElementById('resample_44k').checked ? 1 : 0;
    }

    if (!isMelodyMode) {
        var modelSelector = document.getElementById('modelSelector')
        var modelSize = modelSelector.value;
        socket.emit('submit_sliders', {values: slidersData, prompt:textData, model:modelSize, use_advanced: useAdvanced ? 1 : 0});
        return;
    }

    // Melody 模式：校验上传
    var audioElement = document.getElementById('audio-preview');
    var audioSrc = audioElement.src;
    if (!audioSrc || audioSrc.trim() === "") {
        setStatusText('请先上传旋律音频');
        return;
    }
    socket.emit('submit_sliders', {values: slidersData, prompt:textData, model:'melody', melodyUrl:audioSrc, use_advanced: useAdvanced ? 1 : 0});
}

function setStatusText(msg){
    const statusText = document.getElementById('status-text');
    if (statusText) statusText.textContent = msg;
}

function initModes(){
    const btnText = document.getElementById('mode-text');
    const btnMelody = document.getElementById('mode-melody');
    const textPanel = document.getElementById('text-mode-panel');
    const melodyPanel = document.getElementById('melody-mode-panel');

    function activate(mode){
        if (mode === 'text'){
            btnText.classList.add('active');
            btnMelody.classList.remove('active');
            textPanel.style.display = '';
            melodyPanel.style.display = 'none';
        } else {
            btnMelody.classList.add('active');
            btnText.classList.remove('active');
            melodyPanel.style.display = '';
            textPanel.style.display = 'none';
        }
    }

    btnText.addEventListener('click', () => activate('text'));
    btnMelody.addEventListener('click', () => activate('melody'));
    activate('text');

    // 上传校验与缓存
    const fileInput = document.getElementById('melody');
    const audioElement = document.getElementById('audio-preview');
    const uploadStatus = document.getElementById('melody-upload-status');
    const uploadCheck = document.getElementById('melody-check');
    fileInput.addEventListener('change', async function(event) {
        const files = event.target.files;
        if (files.length === 0) {
            audioElement.src = "";
            if (uploadStatus){ uploadStatus.textContent = '未上传'; uploadStatus.className = 'upload-status'; }
            if (uploadCheck) uploadCheck.style.display = 'none';
            return;
        }
        const file = files[0];
        if (!file.type.startsWith('audio/')) {
            audioElement.src = "";
            setStatusText('请选择音频文件');
            if (uploadStatus){ uploadStatus.textContent = '格式不支持'; uploadStatus.className = 'upload-status upload-fail'; }
            if (uploadCheck) uploadCheck.style.display = 'none';
            return;
        }
        const formData = new FormData();
        formData.append('melody', file);
        try {
            const response = await fetch('/upload_melody', { method: 'POST', body: formData });
            const data = await response.json();
            if (data.filePath){
                // 使用相对路径，避免提交绝对 URL 导致后端校验失败
                const rel = data.filePath.replace(location.origin + '/', '');
                audioElement.src = rel;
                setStatusText('上传完成');
                if (uploadStatus){ uploadStatus.textContent = '上传完成'; uploadStatus.className = 'upload-status upload-ok'; }
                if (uploadCheck) uploadCheck.style.display = '';
            } else {
                setStatusText('上传失败');
                if (uploadStatus){ uploadStatus.textContent = '上传失败'; uploadStatus.className = 'upload-status upload-fail'; }
                if (uploadCheck) uploadCheck.style.display = 'none';
            }
        } catch(err){
            audioElement.src = "";
            setStatusText('上传失败');
            if (uploadStatus){ uploadStatus.textContent = '上传失败'; uploadStatus.className = 'upload-status upload-fail'; }
            if (uploadCheck) uploadCheck.style.display = 'none';
        }
    });
}

function initAdvancedPanel(){
    const panel = document.getElementById('advanced-panel');
    const header = document.getElementById('advanced-header');
    const resetBtn = document.getElementById('reset-adv');
    if (!panel || !header || !resetBtn) return;
    header.addEventListener('click', () => {
        panel.classList.toggle('collapsed');
    });
    resetBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        // 推荐值重置
        setSlider('top_k', 250);
        setSlider('top_p', 0.67);
        setSlider('temperature', 1.2);
        setSlider('cfg_coef', 4.0);
        setSlider('duration', 30);
        document.getElementById('two_step_cfg').checked = false;
        document.getElementById('seed-fixed').checked = true;
        // 保留当前种子数值不变
        setSlider('loudness_headroom_db', 18);
        setSlider('fade_ms', 60);
        document.getElementById('resample_44k').checked = false;
        setStatusText('已重置为推荐值');
    });
}

function setSlider(id, val){
    const range = document.getElementById(id);
    const text = document.getElementById(id+'-text');
    if (range) range.value = val;
    if (text) text.value = val;
}

// 参数说明提示
function initParamHints(){
    const HINTS = {
        top_k: {
            desc: '限制采样时只从最高概率的K个token中选择。较大更丰富，较小更稳定。',
            recommend: '推荐: 150–350'
        },
        top_p: {
            desc: '核采样阈值，选择累计概率达到P的token集合。较大更随机，较小更保守。',
            recommend: '推荐: 0.6–0.8'
        },
        temperature: {
            desc: '采样温度，>1 更随机、<1 更确定。过高可能失真。',
            recommend: '推荐: 0.9–1.3'
        },
        cfg_coef: {
            desc: 'Classifier-Free Guidance 强度，数值越大越遵循提示词，但可能牺牲自然度。',
            recommend: '推荐: 3.5–5.0'
        },
        duration: {
            desc: '生成时长（秒）。越长耗时和显存越高。',
            recommend: '推荐: 10–30s 试验，满意后再加长'
        },
        two_step_cfg: {
            desc: '启用两阶段 CFG，通常更贴合提示词，耗时略增。',
            recommend: '推荐: 关闭; 想强化提示遵循时可开启'
        },
        seed: {
            desc: '固定随机种子以复现实验结果；不固定更具多样性。',
            recommend: '推荐: 先随机，满意后记录种子'
        },
        loudness_headroom_db: {
            desc: '响度预留，越小越响但风险失真，越大更稳。',
            recommend: '推荐: 16–18dB'
        },
        fade_ms: {
            desc: '生成音频首尾淡入淡出长度，可减少爆音/点击声。',
            recommend: '推荐: 40–100ms'
        },
        resample_44k: {
            desc: '将输出从 32kHz 重采样到 44.1kHz，兼容性更好但有轻微重采样损耗。',
            recommend: '推荐: 需要时开启'
        }
    };

    let tooltipEl = null;
    function ensureTooltip(){
        if (!tooltipEl){
            tooltipEl = document.createElement('div');
            tooltipEl.className = 'tooltip';
            document.body.appendChild(tooltipEl);
        }
        return tooltipEl;
    }
    function showTooltip(target, text){
        const el = ensureTooltip();
        el.textContent = text;
        const rect = target.getBoundingClientRect();
        const top = rect.top + window.scrollY - el.offsetHeight - 8;
        const left = rect.left + window.scrollX + rect.width/2 - Math.min(260, el.offsetWidth)/2;
        el.style.top = (top < 0 ? rect.bottom + window.scrollY + 8 : top) + 'px';
        el.style.left = Math.max(8, left) + 'px';
        el.style.display = 'block';
    }
    function hideTooltip(){ if (tooltipEl) tooltipEl.style.display = 'none'; }

    document.querySelectorAll('.param-field').forEach(function(field){
        const id = field.getAttribute('data-param');
        const infoIcon = field.querySelector('.info-icon');
        const data = HINTS[id];
        if (!data || !infoIcon) return;
        const text = `${data.desc}  ${data.recommend}`;
        infoIcon.addEventListener('mouseenter', () => showTooltip(infoIcon, text));
        infoIcon.addEventListener('mouseleave', hideTooltip);
        infoIcon.addEventListener('mousemove', (e) => {
            if (!tooltipEl || tooltipEl.style.display !== 'block') return;
            tooltipEl.style.top = (e.pageY + 12) + 'px';
            tooltipEl.style.left = (e.pageX + 12) + 'px';
        });
    });
}

// ADD TO QUEUE

socket.on('add_to_queue', function(data) {
    addPromptToQueue(data.prompt);
});

function addPromptToQueue(prompt_data) {
    const promptListDiv = document.querySelector('.prompt-queue');

    const promptItemDiv = document.createElement('div');
    promptItemDiv.className = 'audio-item';
    promptItemDiv.setAttribute('completed-segments', '0');
    promptItemDiv.setAttribute('data-max-tokens', '0');

    promptItemDiv.style.background = 'linear-gradient(to right, blue 0%, transparent 0%)';
    const promptItemTextDiv = document.createElement('div');
    promptItemTextDiv.className = 'audio-item-text';
    promptItemTextDiv.textContent = prompt_data;

    promptItemDiv.appendChild(promptItemTextDiv);
    promptListDiv.appendChild(promptItemDiv);
}

// AUDIO RENDERED

socket.on('on_finish_audio', function(data) {
    const promptListDiv = document.querySelector('.prompt-queue');
    const firstPromptItem = promptListDiv.querySelector('.audio-item');
    if (firstPromptItem) {
        promptListDiv.removeChild(firstPromptItem);
    }

    addAudioToList(data.filename, data.json_filename);
});

function makeAudioElement(json_data, filename, use_reverse_ordering) {
    const audioListDiv = document.querySelector('.audio-list');

    const audioItemDiv = document.createElement('div');
    audioItemDiv.className = 'audio-item';

    const promptDiv = document.createElement('div');
    promptDiv.className = 'audio-item-text';
    promptDiv.textContent = `${json_data.prompt}`;

    const parametersDiv = document.createElement('div');
    parametersDiv.className = 'audio-item-params';

    const modelDiv = document.createElement('div');
    modelDiv.className = 'audio-item-text';
    modelDiv.textContent = `Model: ${json_data.model}`;
    parametersDiv.appendChild(modelDiv);

    for (const key in json_data.parameters) {
        const paramDiv = document.createElement('div');
        paramDiv.className = 'audio-item-text';
        paramDiv.textContent = `${key}: ${json_data.parameters[key]}`;
        parametersDiv.appendChild(paramDiv);
    }

    const audio = document.createElement('audio');
    audio.controls = true;

    const source = document.createElement('source');
    source.src = filename;
    source.type = 'audio/wav';

    audioItemDiv.appendChild(promptDiv);
    audio.appendChild(source);
    audioItemDiv.appendChild(audio);
    audioItemDiv.appendChild(parametersDiv);

    console.log(use_reverse_ordering)

    if(use_reverse_ordering) {
        audioListDiv.appendChild(audioItemDiv);
        return
    }

    if (audioListDiv.firstChild) {
        audioListDiv.insertBefore(audioItemDiv, audioListDiv.firstChild);
    } else {
        audioListDiv.appendChild(audioItemDiv);
    }
}

function addAudioToList(filename, json_filename) {
    fetch(json_filename)
    .then(response => response.json())
    .then(json_data => makeAudioElement(json_data, filename, false))
}

// PROGRESS
const rootStyles = getComputedStyle(document.documentElement);  
const completionColor = rootStyles.getPropertyValue('--hamster').trim();  

socket.on('progress', function(data) {
    progress_value = data.progress * 100;

    const promptListDiv = document.querySelector('.prompt-queue');
    const firstPromptItem = promptListDiv.querySelector('.audio-item');

    if (firstPromptItem) {
        firstPromptItem.style.background = `linear-gradient(to right, ${completionColor} ${progress_value}%, transparent ${progress_value}%)`;
        firstPromptItem.querySelector('.audio-item-text').style.textShadow = '1px 3px 6px black';
    }
    // 更新状态栏
    const statusFill = document.getElementById('status-fill');
    const statusText = document.getElementById('status-text');
    if (statusFill) statusFill.style.width = `${Math.min(100, Math.max(0, progress_value))}%`;
    if (statusText) statusText.textContent = `生成中 ${Math.floor(progress_value)}%`;
});

// 简短状态与错误提示
socket.on('status', function(data) {
    const statusFill = document.getElementById('status-fill');
    const statusText = document.getElementById('status-text');
    if (!statusFill || !statusText) return;
    if (data.state === 'started') {
        statusFill.style.width = '2%';
        statusText.textContent = '开始生成';
    } else if (data.state === 'finished') {
        statusFill.style.width = '100%';
        statusText.textContent = '完成';
        setTimeout(() => { statusFill.style.width = '0%'; statusText.textContent = '就绪'; }, 1200);
    } else if (data.state === 'error') {
        statusText.textContent = '出错';
        statusFill.style.width = '0%';
    }
});

socket.on('error', function(data) {
    const statusText = document.getElementById('status-text');
    if (statusText) statusText.textContent = `错误: ${data.message}`;
    // 可选：弹窗提示
    console.error('生成错误: ', data.message);
});

function addAudiosToList(pairs) {
    // Use map to transform each pair into a fetch promise
    const fetchPromises = pairs.map(pair => {
        const [filename, json_filename] = pair;
        return fetch(json_filename)
            .then(response => {
                const lastModified = response.headers.get("Last-Modified");
                const lastModifiedDate = new Date(lastModified);
                return response.json().then(json_data => {
                    return { json_data, filename, lastModifiedDate };
                });
            });
    });

    const audioListDiv = document.querySelector('.audio-list');
    while (audioListDiv.firstChild) {
        audioListDiv.removeChild(audioListDiv.firstChild);
    }  
    
    Promise.all(fetchPromises)
    .then(results => {
        const sortedResults = results.sort((a, b) => b.lastModifiedDate - a.lastModifiedDate);
        
        sortedResults.forEach(item => {
            makeAudioElement(item.json_data, item.filename, true);
        });
    })
    .catch(error => {
        console.error("Error fetching data:", error);
    });
}

// INITIALIZE

socket.on('audio_json_pairs', function(data) {
    addAudiosToList(data)
});
