#!/bin/bash

echo $CREATE

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x
find . -print

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

###################################################################################
###################################################################################

if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
fi

# Setup pipeline slave
slave_setup

in_prog=$(cf active-deploy-list | grep "${CF_APP}_${UPDATE_ID}")
read -a array <<< "$in_prog"
CREATE=${array[0]}
echo "========> id in progress: ${CREATE}"

if [ "$USER_TEST" = true ]; then
  cf active-deploy-advance $CREATE
  wait_for_update $CREATE rampdown 600 && rc=$? || rc=$?
  echo "wait result is $rc"
  cf active-deploy-list
  if (( $rc )); then
    echo "ERROR: update failed"
    echo cf-active-deploy-rollback $CREATE
    wait_for_update $CREATE initial 600 && rc=$? || rc=$?
    cf active-deploy-delete $CREATE
    exit 1
  fi
  # Cleanup
  cf active-deploy-delete $CREATE -f
else
  cf active-deploy-rollback $CREATE
  cf active-deploy-delete $CREATE -f
fi
