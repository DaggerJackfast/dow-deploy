#!/bin/bash

set -e
# load variables from .env file
set -a
source .env
set +a


function printLog() {
  local message="$1"
  echo "=== ${message} ==="
}

function buildAndPushImage(){
  local directory=$(realpath "$1")
  local docker_image="$2"
  cd ${directory}
    IMAGE=${docker_image} docker-compose build
    IMAGE=${docker_image} docker-compose push
  cd -
}

function copyComposeFiles(){
  local source_dir="$1"
  local destination_dir="$2"
  local compose_file=${source_dir}/docker-compose.yaml
  echo "compose_file=${compose_file}"
  mkdir -p ${destination_dir}
  cp ${compose_file} ${destination_dir}
}

function copyEnvironmentFiles(){
  local source_dir="$1"
  local destination_dir="$2"
  # pass 2 arguments before rest array arguments
  shift 2
  local files=("$@")
  mkdir -p ${destination_dir}
  for file in "${files[@]}";
  do
    echo "file=$file"
    cp ${source_dir}/${file} ${destination_dir}
  done
}

function copyRunScriptFiles(){
  local source_dir="$1"
  local destination_dir="$2"
  local script_file=${source_dir}/scripts/run_docker.sh
  local destination_scripts_dir=${destination_dir}/scripts
  echo "script_file=${script_file}"
  mkdir -p ${destination_scripts_dir}
  cp ${script_file} ${destination_scripts_dir}
}

function makeArchive() {
  local run_directory="$1"
  local archive_directory_name="$2"
  local archive_name="$3"
  cd $(realpath ${run_directory})
    tar -czvf ${archive_name} ${archive_directory_name}
  cd -
}

build_dir="build"
project_dir_name="project"
project_dir="${build_dir}/${project_dir_name}"

rm -rf $build_dir
mkdir -p $project_dir

echo $DOCKER_PASSWORD | docker login --username=${DOCKER_USER} ${DOCKER_REGISTRY} --password-stdin

printLog "Building and deploying images..."
buildAndPushImage ${CURRENT_DOW_BOT_DIRECTORY} ${DOCKER_DOW_BOT_IMAGE}
buildAndPushImage ${CURRENT_DOW_DASH_DIRECTORY} ${DOCKER_DOW_DASH_IMAGE}

printLog "Copying docker-compose files for building..."
copyComposeFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot
copyComposeFiles ${CURRENT_DOW_DASH_DIRECTORY} ${project_dir}/dow-dash
copyComposeFiles ${CURRENT_DOW_REDIS_DIRECTORY} ${project_dir}/dow-redis

printLog "Copying run_docker files for building..."
copyRunScriptFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot
copyRunScriptFiles ${CURRENT_DOW_DASH_DIRECTORY} ${project_dir}/dow-dash
copyRunScriptFiles ${CURRENT_DOW_REDIS_DIRECTORY} ${project_dir}/dow-redis

printLog "Copying environment variables files for building..."
bot_env_files=(".env.production" ".env.database")
copyEnvironmentFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot "${bot_env_files[@]}"
dash_env_files=(".env.production")
copyEnvironmentFiles ${CURRENT_DOW_DASH_DIRECTORY} ${project_dir}/dow-dash "${dash_env_files[@]}"
redis_env_files=(".env.redis")
copyEnvironmentFiles ${CURRENT_DOW_REDIS_DIRECTORY} ${project_dir}/dow-redis "${redis_env_files[@]}"

printLog "Making project archive..."
current_date=$(date +'%m-%d-%Y_%H-%M-%S')
project_archive="project_${current_date}.tar.gz"
makeArchive ${build_dir} ${project_dir_name} ${project_archive}
printLog "Creating directory in remote server..."
project_archive_file="${build_dir}/${project_archive}"
ssh -i "${REMOTE_SSH_KEY_FILE}" -t ${REMOTE_USER}@${REMOTE_SERVER} "mkdir -p ${REMOTE_DIRECTORY}"
printLog "Copying to remote server..."
scp -i "${REMOTE_SSH_KEY_FILE}" ${project_archive_file} ${REMOTE_USER}@${REMOTE_SERVER}:${REMOTE_DIRECTORY}
printLog "Deploying docker containers in remote server..."

ssh -i "${REMOTE_SSH_KEY_FILE}" -t ${REMOTE_USER}@${REMOTE_SERVER} << EOF
  cd ${REMOTE_DIRECTORY}

  tar -xzvf ${project_archive}
  rm -rf ${project_archive}

  /usr/bin/bash ${project_dir_name}/dow-redis/scripts/run_docker.sh

  echo $DOCKER_PASSWORD | docker login --username=${DOCKER_USER} ${DOCKER_REGISTRY} --password-stdin

  /usr/bin/bash ${project_dir_name}/dow-dash/scripts/run_docker.sh ${DOCKER_DOW_DASH_IMAGE}

  /usr/bin/bash ${project_dir_name}/dow-bot/scripts/run_docker.sh ${DOCKER_DOW_BOT_IMAGE}

EOF
printLog "Finished deploy"
