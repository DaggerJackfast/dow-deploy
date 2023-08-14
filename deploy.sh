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

function deployBack() {
  local build_dir="build"
  local project_dir_name="project"
  local project_dir="${build_dir}/${project_dir_name}"

  rm -rf $build_dir
  mkdir -p $project_dir

  echo $DOCKER_PASSWORD | docker login --username=${DOCKER_USER} ${DOCKER_REGISTRY} --password-stdin

  printLog "Building and deploying images..."
  buildAndPushImage ${CURRENT_DOW_BOT_DIRECTORY} ${DOCKER_DOW_BOT_IMAGE}

  printLog "Copying docker-compose files for building..."
  copyComposeFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot

  printLog "Copying run_docker files for building..."
  copyRunScriptFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot

  printLog "Copying environment variables files for building..."
  local bot_env_files=(".env.production")
  copyEnvironmentFiles ${CURRENT_DOW_BOT_DIRECTORY} ${project_dir}/dow-bot "${bot_env_files[@]}"

  printLog "Making project archive..."
  local current_date=$(date +'%m-%d-%Y_%H-%M-%S')
  local project_archive="project_${current_date}.tar.gz"
  makeArchive ${build_dir} ${project_dir_name} ${project_archive}

  printLog "Creating directory in remote server..."
  local project_archive_file="${build_dir}/${project_archive}"
  ssh -i "${REMOTE_SSH_KEY_FILE}" -t ${REMOTE_USER}@${REMOTE_SERVER} "mkdir -p ${REMOTE_DIRECTORY}"

  printLog "Copying to remote server..."
  scp -i "${REMOTE_SSH_KEY_FILE}" ${project_archive_file} ${REMOTE_USER}@${REMOTE_SERVER}:${REMOTE_DIRECTORY}
  printLog "Deploying docker containers in remote server..."

  ssh -i "${REMOTE_SSH_KEY_FILE}" -t ${REMOTE_USER}@${REMOTE_SERVER} << EOF
    cd ${REMOTE_DIRECTORY}

    tar -xzvf ${project_archive}
    rm -rf ${project_archive}

    echo $DOCKER_PASSWORD | docker login --username=${DOCKER_USER} ${DOCKER_REGISTRY} --password-stdin

    /usr/bin/bash ${project_dir_name}/dow-bot/scripts/run_docker.sh ${DOCKER_DOW_BOT_IMAGE}
EOF

  printLog "Cleaning unused docker build cache objects"
  docker system prune -f
}

function deployFront() {
  printLog "Deploy to cloudflare pages"
  cd ${CURRENT_DOW_DASH_DIRECTORY}
    [[ -s $HOME/.nvm/nvm.sh ]] && . $HOME/.nvm/nvm.sh
    nvm use
    /usr/bin/bash ./scripts/deploy.sh ${CLOUDFLARE_ACCOUNT_ID} ${CLOUDFLARE_API_TOKEN} ${CLOUDFLARE_PAGE_PROJECT_NAME}
  cd -
}

function printHelp() {
  echo \
"Deploy dowdash bot script:
   Syntax: ./deploy [--front|--back|--help]
   options:
   --front  deploy dow-dash to cloudflare pages
   --back   deploy dow-bot to remote server
   --help   show help
If run without options front and back will be deployed."
}

if [[ "$*" =~ .*"--help".* ]]
then
  printHelp
  exit 0
fi

if [ -z "$*" ]
then
  deployBack
  deployFront
else
  for i in $*;
    do
      if [[ "$i" == "--back" ]]
      then
        deployBack
      elif  [[ "$i" == '--front' ]]
      then
        deployFront
      fi
    done
fi

printLog "Finished deploy"
