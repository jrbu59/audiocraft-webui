#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Parse arguments
USE_CONDA=false
FORCE_CPU=false
for arg in "$@"; do
    if [ "$arg" == "--conda" ]; then
        USE_CONDA=true
    elif [ "$arg" == "--cpu" ]; then
        FORCE_CPU=true
    fi
done

# Check for Python 3.10 or Conda
if [ "$USE_CONDA" == true ] || ! command_exists python3.10; then
    echo "Python 3.10 is not installed or --conda flag is used. Checking for Conda..."
    if command_exists conda; then
        echo "Conda is installed. Using Conda to create an environment."
        if [ ! -d "venv" ]; then
            echo "Creating Conda environment..."
            conda create --yes --prefix ./venv python=3.10
        else
            echo "Conda environment already exists."
        fi
        source activate ./venv
    else
        echo "Neither Python 3.10 nor Conda are installed! Install one and rerun the script."
        exit 1
    fi
else
    echo "Python 3.10 is installed. Using Python virtual environment."
    if [ ! -d "venv" ]; then
        echo "Creating virtual environment..."
        python3.10 -m venv venv
    else
        echo "Virtual environment already exists."
    fi
    source venv/bin/activate
fi

# Install PyTorch stack (match CUDA or CPU)
echo "Installing PyTorch stack (torch/torchaudio/torchvision)..."
pip install --upgrade pip

if [ "$FORCE_CPU" == true ]; then
    echo "Forcing CPU installation of torch stack..."
    pip install --index-url https://download.pytorch.org/whl/cpu \
        torch==2.1.0 torchaudio==2.1.0 torchvision==0.16.0
else
    # Try CUDA 12.1 wheels (driver 12.6 兼容 12.1)
    echo "Installing CUDA 12.1 wheels for torch stack..."
    pip install --index-url https://download.pytorch.org/whl/cu121 \
        torch==2.1.0 torchaudio==2.1.0 torchvision==0.16.0 || {
        echo "CUDA 12.1 wheels failed; falling back to CPU wheels...";
        pip install --index-url https://download.pytorch.org/whl/cpu \
            torch==2.1.0 torchaudio==2.1.0 torchvision==0.16.0;
    }
fi

# Install remaining Python dependencies
if [ -f "requirements.txt" ]; then
    echo "Installing project requirements..."
    pip install -r requirements.txt
else
    echo "requirements.txt file not found!"
fi

# If using Conda, prefer conda-forge builds for av/ffmpeg and C++ runtime to avoid CXXABI issues
if [ "$USE_CONDA" == true ]; then
    echo "Ensuring av/ffmpeg/libstdc++ come from conda-forge to avoid ABI mismatch..."
    conda config --add channels conda-forge
    conda config --set channel_priority strict
    # Replace any pip-installed av with conda build (safe if not present)
    pip uninstall -y av || true
    conda install --yes -c conda-forge \
        av 'ffmpeg>=6' 'libstdcxx-ng>=12' 'tbb>=2021.11'
    echo "Validating av import..."
    python - <<'PY'
try:
    import av
    print("PyAV import OK:", av.__version__)
except Exception as e:
    import sys
    print("PyAV import failed:", e, file=sys.stderr)
    sys.exit(1)
PY
fi

# Deactivate virtual environment
if [ "$USE_CONDA" == true ]; then
    conda deactivate
else
    deactivate
fi

echo "Script completed."
