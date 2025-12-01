#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

#!/bin/bash

# Parse arguments
USE_CONDA=true
CONDA_ENV_NAME="audiocraft"
NEXT_IS_ENV=false
for arg in "$@"; do
    if [ "$NEXT_IS_ENV" = true ]; then
        CONDA_ENV_NAME="$arg"
        NEXT_IS_ENV=false
        continue
    fi
    case "$arg" in
        --conda)
            USE_CONDA=true
            ;;
        --conda-env)
            NEXT_IS_ENV=true
            ;;
        *)
            ;;
    esac
done

# Activate the appropriate environment
if [ "$USE_CONDA" == true ]; then
    echo "Activating Conda environment: $CONDA_ENV_NAME ..."
    if command_exists conda; then
        # Ensure conda is available in non-interactive shells
        CONDA_BASE="$(conda info --base 2>/dev/null)" || CONDA_BASE=""
        if [ -n "$CONDA_BASE" ] && [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
            # shellcheck source=/dev/null
            source "$CONDA_BASE/etc/profile.d/conda.sh"
        fi
        if conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV_NAME"; then
            conda activate "$CONDA_ENV_NAME" || { echo "Failed to activate Conda env '$CONDA_ENV_NAME'."; exit 1; }
        else
            echo "Conda env '$CONDA_ENV_NAME' not found. Create it via:"
            echo "  conda create -n $CONDA_ENV_NAME python=3.10"
            exit 1
        fi
    else
        echo "Conda is not installed! Install Conda and try again."
        exit 1
    fi
else
    if [ -d "venv" ]; then
        echo "Activating virtual environment..."
        source venv/bin/activate
    else
        echo "Virtual environment does not exist! Run setup script first."
        exit 1
    fi
fi

# Prefer Conda-provided C++ runtime to avoid system ABI mismatch
if [ -n "$CONDA_PREFIX" ] && [ -f "$CONDA_PREFIX/lib/libstdc++.so.6" ]; then
    echo "Setting LD_LIBRARY_PATH and LD_PRELOAD from Conda env to avoid CXXABI issues..."
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:${LD_LIBRARY_PATH:-}"
    export LD_PRELOAD="$CONDA_PREFIX/lib/libstdc++.so.6${LD_PRELOAD:+:$LD_PRELOAD}"
fi

export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890

# Handle script interruption (CTRL+C) and ensure environment deactivation
trap "echo 'Interrupt received, deactivating environment...'; if [ '$USE_CONDA' == 'true' ]; then conda deactivate; else deactivate; fi; exit 1" SIGINT SIGTERM

# Run webui.py
if [ -f "webui.py" ]; then
    echo "Starting web UI..."
    python webui.py
else
    echo "webui.py not found!"
    exit 1
fi

# Deactivate virtual environment after execution
if [ "$USE_CONDA" == true ]; then
    conda deactivate
else
    deactivate
fi

echo "Script completed."
