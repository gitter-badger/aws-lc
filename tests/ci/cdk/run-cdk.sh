#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

set -exuo pipefail

# -e: Exit on any failure
# -x: Print the command before running
# -u: Any variable that is not set will cause an error if used
# -o pipefail: Makes sure to exit a pipeline with a non-zero error code if any command in the pipeline exists with a
#              non-zero error code.

# Export customized environment variables.
export CDK_DEPLOY_ACCOUNT=$1
shift
export CDK_DEPLOY_REGION=$1
shift
export GITHUB_REPO_OWNER=$1
shift
export GITHUB_REPO=$1
shift
export ACTION=$1
shift

# Export other environment variables.
export DATE_NOW="$(date +%Y-%m-%d-%H-%M)"
export ECR_LINUX_AARCH_REPO_NAME="aws-lc-test-docker-images-linux-aarch"
export ECR_LINUX_X86_REPO_NAME="aws-lc-test-docker-images-linux-x86"
export ECR_WINDOWS_REPO_NAME="aws-lc-test-docker-images-windows"
export S3_FOR_WIN_DOCKER_IMG_BUILD="windows-docker-images-${DATE_NOW}"
export WIN_EC2_TAG_KEY="aws-lc"
export WIN_EC2_TAG_VALUE="windows-docker-img-${DATE_NOW}"
export WIN_DOCKER_BUILD_SSM_DOCUMENT="windows-ssm-document-${DATE_NOW}"

# Functions
function create_aws_resources() {
  cdk deploy aws-lc-test-* --require-approval never
}

function build_linux_img() {
  aws codebuild start-build --project-name ${ECR_LINUX_AARCH_REPO_NAME}
  aws codebuild start-build --project-name ${ECR_LINUX_X86_REPO_NAME}
}

function build_windows_img() {
  # Upload windows docker file and build scripts to S3.
  cd ../docker_images
  zip -r -X "windows.zip" "./windows"
  aws s3 cp "windows.zip" "s3://${S3_FOR_WIN_DOCKER_IMG_BUILD}/"
  rm windows.zip

  # EC2 takes 10 min to be ready for running command.
  echo "Wait 10 min for EC2 ready for SSM command execution."
  sleep 600

  instance_id=$(aws ec2 describe-instances \
    --filters "Name=tag:${WIN_EC2_TAG_KEY},Values=${WIN_EC2_TAG_VALUE}" | jq -r '.Reservations[0].Instances[0].InstanceId')

  # Run commands on windows EC2 instance to build windows docker images.
  for i in {1..60}; do
    instance_ping_status=$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" | jq -r '.InstanceInformationList[0].PingStatus')
    if [[ "${instance_ping_status}" == "Online" ]]; then
      # https://awscli.amazonaws.com/v2/documentation/api/latest/reference/ssm/send-command.html
      aws ssm send-command \
        --instance-ids "${instance_id}" \
        --document-name "${WIN_DOCKER_BUILD_SSM_DOCUMENT}" \
        --output-s3-bucket-name "${S3_FOR_WIN_DOCKER_IMG_BUILD}" \
        --output-s3-key-prefix 'runcommand'
      echo "Windows ec2 is executing SSM command."
      return
    else
      echo "${i}: Current instance ping status: ${instance_ping_status}. Wait 1 minute to retry SSM command execution."
      sleep 60
    fi
  done
  echo "After 30 minutes, Windows ec2 is still not ready for SSM commands execution. Exit."
  exit 1
}

function destroy_docker_img_build_stack() {
  # Destroy all temporary resources created for all docker image build.
  cdk destroy aws-lc-test-docker-images-build-* --force
}

function images_pushed_to_ecr() {
  repo_name=$1
  shift
  target_images=("$@")
  ecr_repo_name="${CDK_DEPLOY_ACCOUNT}.dkr.ecr.${CDK_DEPLOY_REGION}.amazonaws.com/${repo_name}"
  echo "Checking if docker images [${target_images[@]}] are pushed to ${ecr_repo_name}."

  # Every 5 min, this function checks if the target docker img is created.
  # Normally, docker img build can take up to 1 hour. Here, we wait up to 30 * 5 min.
  for i in {1..30}; do
    images_in_ecr=$(aws ecr describe-images --repository-name ${repo_name})
    images_pushed=0
    for target_image in "${target_images[@]}"; do
      if [[ ${images_in_ecr} != *"$target_image"* ]]; then
        images_pushed=1
        break
      fi
    done
    if [[ ${images_pushed} == 0 ]]; then
      echo "All required images are pushed to ${ecr_repo_name}."
      return
    else
      echo "${i}: Wait 5 min for docker image creation."
      sleep 300
    fi
  done
  echo "Error: Images are not pushed to ${ecr_repo_name}. Exit."
  exit 1
}

function deploy() {
  # Always destroy docker build stacks (which include EC2 instance) on EXIT.
  trap destroy_docker_img_build_stack EXIT

  echo "Creating AWS resources through CDK."
  create_aws_resources

  echo "Activating AWS CodeBuild to build Linux aarch & x86 docker images."
  build_linux_img

  echo "Executing AWS SSM commands to build Windows docker images."
  build_windows_img

  echo "Waiting for docker images creation. Building the docker images need to take 1 hour."
  linux_aarch_img_tags=("ubuntu-19.10_gcc-9x_latest"
    "ubuntu-19.10_clang-9x_latest"
    "ubuntu-19.10_clang-9x_sanitizer_latest")
  images_pushed_to_ecr "${ECR_LINUX_AARCH_REPO_NAME}" "${linux_aarch_img_tags[@]}"
  linux_x86_img_tags=("ubuntu-18.04_gcc-7x_latest"
    "ubuntu-16.04_gcc-5x_latest"
    "ubuntu-18.04_clang-6x_latest"
    "ubuntu-19.10_gcc-9x_latest"
    "ubuntu-19.10_clang-9x_sanitizer_latest"
    "ubuntu-19.10_clang-9x_latest"
    "ubuntu-19.04_gcc-8x_latest"
    "ubuntu-19.04_clang-8x_latest"
    "centos-7_gcc-4x_latest"
    "amazonlinux-2_gcc-7x_latest"
    "s2n_integration_clang-9x_latest")
  images_pushed_to_ecr "${ECR_LINUX_X86_REPO_NAME}" "${linux_x86_img_tags[@]}"
  windows_img_tags=("vs2015_latest" "vs2017_latest")
  images_pushed_to_ecr "${ECR_WINDOWS_REPO_NAME}" "${windows_img_tags[@]}"
}

function destroy() {
  cdk destroy aws-lc-test-* --force
}

# Main logics

case ${ACTION} in
DEPLOY)
  deploy
  ;;
DIFF)
  cdk diff aws-lc*
  ;;
SYNTH)
  cdk synth aws-lc*
  ;;
DESTROY)
  destroy
  ;;
*)
  echo "Action: ${ACTION} is not supported."
  ;;
esac

exit 0
