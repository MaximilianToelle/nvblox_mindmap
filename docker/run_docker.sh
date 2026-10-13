#!/bin/bash
# NOTE(remos): This docker run script has been taken
# and modified from the nvblox core repo.
set -e

# Default mount directories on the host machine for the datasets, models and evaluation outputs,
# inside the repo (the script is run from the repo root, see the "." mount below)
DATASETS_HOST_MOUNT_DIRECTORY="$PWD/datasets"
MODELS_HOST_MOUNT_DIRECTORY="$PWD/models"
EVAL_HOST_MOUNT_DIRECTORY="$PWD/eval"
MOUNT_ISAACLAB=true

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while getopts ":a:d:m:e:ohb" OPTION; do
    case $OPTION in
        a)
            ADDITIONAL_DOCKER_ARGS=$OPTARG
            ;;
        d)
            DATASETS_HOST_MOUNT_DIRECTORY=$OPTARG
            ;;
        m)
            MODELS_HOST_MOUNT_DIRECTORY=$OPTARG
            ;;
        e)
            EVAL_HOST_MOUNT_DIRECTORY=$OPTARG
            ;;
        o)
            MOUNT_HOME=true
            ;;
        b)
            BUILD=true
            ;;
        h)
            echo "Run the nvblox docker"
            echo "Usage:"
            echo "run_docker.sh -a \"additional_docker_args\" -d \"datasets_host_mount_directory\""
            echo "run_docker.sh -h"
            echo ""
            echo "  -a Additional arguments passed to docker run."
            echo "  -d Datasets directory to be mounted on the host machine. Defaults to datasets/ in the repo."
            echo "  -m Models directory to be mounted on the host machine. Defaults to models/ in the repo."
            echo "  -b Build the images before starting the container"
            echo "  -e Evaluation directory to be mounted on the host machine. Defaults to eval/ in the repo."
            echo "  -o Mount the local user's home directory."
            echo "  -h help (this output)"
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done


# This portion of the script will only be executed *inside* the docker when
# this script is used as entrypoint further down. It runs as the host user, whose account is
# created when the image is built (see Dockerfile.mindmap_deps), s.t. created files have correct ownership.
if [ -f /.dockerenv ]
then
    set -euo pipefail

    # Make sure that all shared libs are found. This should normally not be needed, but resolves a
    # problem with the opencv installation. For unknown reasons, the command doesn't bite if placed
    # at the end of the dockerfile
    sudo ldconfig

    # Install nvblox, nvblox_torch, and mindmap
    bash -c "source /etc/nvblox_env.sh && $SCRIPT_DIR/install_nvblox.sh"
    bash -c "source /etc/nvblox_env.sh && $SCRIPT_DIR/install_mindmap.sh"

    # Note: During docker build, we install IsaacLab based on a copy of the IsaacLab repo.
    #       For a nicer development workflow, we re-install IsaacLab as editable packages
    #       from the mounted IsaacLab submodule repo.
    # Reinstall IsaacLab packages if the flag is set
    if [ -n "$MOUNT_ISAACLAB" ] && [ "$MOUNT_ISAACLAB" = true ]; then
        echo "Re-installing isaaclab packages from mounted repo"
        . /opt/venv/bin/activate
        cd /workspaces/nvblox_mindmap/submodules/IsaacLab/ && patch -s -N -p1 -r - < ../mindmap-v1.0.0_IsaacLab-v2.1.0.patch || true
        cd /workspaces/nvblox_mindmap/mindmap
        for DIR in /workspaces/nvblox_mindmap/submodules/IsaacLab/source/isaaclab*/; do
            echo "Installing $DIR"
            pip install --no-deps -e "$DIR"
        done
        sudo rm -r /isaac-lab
    fi

    set +x

    GREEN='\033[0;32m'
    IGREEN='\033[0;92m'
    NO_COLOR='\033[0m'

    echo -e "${GREEN}********************************************************"
    echo -e "* ${IGREEN}PERCEPTIVE IL DEV DOCKER"
    echo -e "${GREEN}********************************************************"
    echo -e ${NO_COLOR}
    # Start interactive session
    exec bash
fi

# Build images if requested
MINDMAP_DEPS_IMAGE_NAME="mindmap_deps"
if [ -n "${BUILD}" ]; then
    "$SCRIPT_DIR"/build_images.sh $MINDMAP_DEPS_IMAGE_NAME
fi

# Remove any exited containers
if [ "$(docker ps -a --quiet --filter status=exited --filter name=$MINDMAP_DEPS_IMAGE_NAME)" ]; then
    docker rm $MINDMAP_DEPS_IMAGE_NAME > /dev/null
fi

# If container is running, attach to it, otherwise start
if [ "$( docker container inspect -f '{{.State.Running}}' $MINDMAP_DEPS_IMAGE_NAME 2>/dev/null)" = "true" ]; then
  echo "Container already running. Attaching."
  docker exec -it $MINDMAP_DEPS_IMAGE_NAME bash

else
    # Create the mounted host directories, otherwise docker creates them owned by root.
    mkdir -p "$DATASETS_HOST_MOUNT_DIRECTORY" "$MODELS_HOST_MOUNT_DIRECTORY" "$EVAL_HOST_MOUNT_DIRECTORY" \
             submodules/nvblox/docker_build .cache

    DOCKER_RUN_ARGS+=("--name" "$MINDMAP_DEPS_IMAGE_NAME"
                      "--privileged"
                      "--ulimit" "memlock=-1"
                      "--ulimit" "stack=-1"
                      "--ipc=host"
                      "--net=host"
                      "--runtime=nvidia"
                      # NOTE: NVIDIA_DRIVER_CAPABILITIES=all is set in Dockerfile.mindmap_deps
                      "--gpus=all"
                      "-v" ".:/workspaces/nvblox_mindmap"
                      # Separate nvblox build, s.t. the host's submodules/nvblox/build is left untouched
                      "-v" "./submodules/nvblox/docker_build:/workspaces/nvblox_mindmap/submodules/nvblox/build"
                      "-v" "$DATASETS_HOST_MOUNT_DIRECTORY:/datasets"
                      "-v" "$MODELS_HOST_MOUNT_DIRECTORY:/models"
                      "-v" "$EVAL_HOST_MOUNT_DIRECTORY:/eval"
                      "-v" "/tmp:/tmp"
                      # Needed for denoising during path tracing
                      "-v" "/usr/share/nvidia/nvoptix.bin:/usr/share/nvidia/nvoptix.bin"                 "-v" "/tmp/.X11-unix:/tmp/.X11-unix:rw"
                      "-v" "/var/run/docker.sock:/var/run/docker.sock"
                      "--env" "DISPLAY"
                      "--env" "WANDB_API_KEY=$WANDB_API_KEY"
                      "--env" "MOUNT_ISAACLAB=$MOUNT_ISAACLAB"
                      "--env" "OMNI_USER=\$omni-api-token"
                      "--env" "OMNI_PASS=$OMNI_PASS"
                      # Setting envs for XR: https://isaac-sim.github.io/IsaacLab/v2.1.0/source/how-to/cloudxr_teleoperation.html#run-isaac-lab-with-the-cloudxr-runtime
                      "--env" "XDG_RUNTIME_DIR=/workspaces/nvblox_mindmap/submodules/IsaacLab/openxr/run"
                      "--env" "XR_RUNTIME_JSON=/workspaces/nvblox_mindmap/submodules/IsaacLab/openxr/share/openxr/1/openxr_cloudxr.json"
                      "--entrypoint" "/workspaces/nvblox_mindmap/docker/run_docker.sh"
                      "--workdir" "/workspaces/nvblox_mindmap/mindmap"
                     )

    # Either mount the whole home directory or the essentials only
    if [ -n "${MOUNT_HOME}" ]; then
        DOCKER_RUN_ARGS+=("-v" "$HOME/:/home/$(id -un)")
    else
        DOCKER_RUN_ARGS+=("-v" "$HOME/.Xauthority"
                          "-v" "$HOME/.bash_history:/home/$(id -un)/.bash_history"
                          # Keeps downloaded feature models (and torch.hub code) and the ccache across starts
                          "-v" "./.cache:/home/$(id -un)/.cache"
                         )
    fi

    if [ -n "${ADDITIONAL_DOCKER_ARGS}" ]; then
        DOCKER_RUN_ARGS+=($ADDITIONAL_DOCKER_ARGS)
    fi

    docker run "${DOCKER_RUN_ARGS[@]}" --interactive --rm --tty "$MINDMAP_DEPS_IMAGE_NAME"
fi
