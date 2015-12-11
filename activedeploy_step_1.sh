#!/bin/bash

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x
find . -print

# Pull in common methods
source ${SCRIPTDIR}/activedeploy_common.sh

function get_originals(){
  local __prefix=$(echo ${1} | cut -c 1-16)
  #EE# local __originals=${2}

  if [[ "CCS" == "${BACKEND}" ]]; then
    read -a originals <<< $(ice group list | grep -v 'Group Id' | grep " ${__prefix}" | awk '{print $1}')
  elif [[ "APPS" == "${BACKEND}" ]]; then
    read -a originals <<< $(cf apps | grep -v "^Getting" | grep -v "^OK" | grep -v "^[[:space:]]*$" | grep -v "^name" | grep "${__prefix}" | awk '{print $1}')
  else
    >&2 echo "ERROR: Unknown backend ${BACKEND}; expected one of \"CCS\" or \"APPS\""
    return 3
  fi
  
  echo ${#originals[@]} original groups found: ${originals[@]}
}

###################################################################################
###################################################################################

if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
  #return 6
fi

# Setup pipeline slave
slave_setup

#EE# TODO: pass in originals variable
get_originals ${CF_APP}

# Determine which original groups has the desired route --> the current original
export route="${ROUTE_HOSTNAME}.${ROUTE_DOMAIN}" 
ROUTED=()

#EE# TODO: make this a function
oldIFS=$IFS
IFS=': ,'
for i in "${originals[@]}"
do   
   echo "Checking routes for ${i}:"
   read -a route_list <<< $(cf app ${i} | grep -v "^Showing" | grep -v "^OK" | grep -v "^[[:space:]]*$" | grep -v "^name" | grep "^urls:")
   #echo $'${route_list[@]:1}\n'
   
   if (( 1 < ${#route_list[@]} )); then
     for j in "${route_list[@]}"
	 do
	    if [[ "${j}" == "${route}" ]]; then
		  ROUTED+=(${i})
		  break
		fi
	 done
   fi  
   unset route_list
done
IFS=$oldIFS

echo ${#ROUTED[@]} of original groups routed to ${route}: ${ROUTED[@]}

if (( 1 < ${#ROUTED[@]} )); then
  echo "WARNING: Selecting only oldest to reroute"
fi

if (( 0 < ${#ROUTED[@]} )); then
  original_grp=${ROUTED[$(expr ${#ROUTED[@]} - 1)]}
  original_grp_id=${original_grp#_*}
fi

successor_grp=${CF_APP}_${UPDATE_ID}

echo "Original group: ${original_grp} (${original_grp_id})"
echo "Successor group: ${successor_grp}  (${UPDATE_ID})"

cf active-deploy-list --timeout 60s

# Do update if there is an original group
if [[ -n "${original_grp}" ]]; then
  echo "Beginning active-deploy update..."
 
  create_command="cf active-deploy-create ${original_grp} ${successor_grp} --manual --quiet --label Explore_${UPDATE_ID} --timeout 60s"
  
  if [[ -n "${RAMPUP}" ]]; then create_command="${create_command} --rampup ${RAMPUP}s"; fi
  if [[ -n "${TEST}" ]]; then create_command="${create_command} --test ${TEST}s"; fi
  if [[ -n "${RAMPDOWN}" ]]; then create_command="${create_command} --rampdown ${RAMPDOWN}s"; fi
  
  echo "Executing update: ${create_command}"
  update=$(${create_command})
  
  if (( $? )); then
    echo "Failed to initiate active deployment; error was:"
    echo ${update}
    exit 1
  fi
  
  echo "Initiated update: ${update}"
  cf active-deploy-show $update --timeout 60s

  CREATE=$update
  #export CREATE
  touch ${SCRIPTDIR}/temp1.sh
  pwd  
  echo "export CREATE=${update}" >> ${SCRIPTDIR}/temp1.sh
  
  # Wait for completion
  wait_for_update $update rampdown 600 && rc=$? || rc=$?
  echo "wait result is $rc"
  
  cf active-deploy-advance $update
  
  wait_for_update $update test 600 && rc=$? || rc=$?
  
  cf active-deploy-list
  
  if (( $rc )); then
    echo "ERROR: update failed"
    echo cf-active-deploy-rollback $update
    wait_for_update $update initial 600 && rc=$? || rc=$?
    cf active-deploy-delete $update -f
    exit 1
  fi
  
  echo $CREATE
fi
