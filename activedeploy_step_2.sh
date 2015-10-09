#!/bin/bash

echo $CREATE

SCRIPTDIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -x
find . -print

install_cf() {  
  #EE# TODO: Change directory
  #MK# TODO: Move to plugin
  mkdir /tmp/cf
  __target_loc="/tmp/cf"

  if [[ -z ${which_cf} || -z $(cf --version | grep "version 6\.12\.2") ]]; then
    local __tmp=/tmp/cf$$.tgz
    wget -O ${__tmp} 'https://cli.run.pivotal.io/stable?release=linux64-binary&version=6.12.2&source=github-rel'
    tar -C ${__target_loc} -xzf ${__tmp}
    rm -f ${__tmp}
  fi
  export PATH=/tmp/cf:$PATH
}

install_active_deploy() {
  #MK# TODO: Move to plugin
  cf uninstall-plugin active-deploy || true
  cf install-plugin ${SCRIPTDIR}/active-deploy-linux-amd64-0.1.38
}

phase_id () {
  local __phase="${1}"
  
  if [[ -z ${__phase} ]]; then
    echo "ERROR: Phase expected"
    return -1
  fi

  case "${__phase}" in
    Initial|initial|start|Start)
    __id=0
    ;;
    Rampup|rampup|RampUp|rampUp)
    __id=1
    ;;
    Test|test|trial|Trial)
    __id=2
    ;;
    Rampdown|rampdown|RampDown|rampDown)
    __id=3
    ;;
    Final|final|End|end)
    __id=4
    ;;
    *)
    >&2 echo "ERROR: Invalid phase $phase"
    return -1
  esac

  echo ${__id}
}

wait_for_update (){
    cf active-deploy-list
	
    local WAITING_FOR=$1 
    local WAITING_FOR_PHASE=$2
    local WAIT_FOR=$3
    
    if [[ -z ${WAITING_FOR} ]]; then
        >&2 echo "ERROR: Expected update identifier to be passed into wait_for"
        return 1
    fi
    [[ -z ${WAITING_FOR_PHASE} ]] && WAITING_FOR_PHASE="Final"
    WAITING_FOR_PHASE_ID=$(phase_id ${WAITING_FOR_PHASE})
    [[ -z ${WAIT_FOR} ]] && WAIT_FOR=600 
    
    start_time=$(date +%s)
    end_time=$(expr ${start_time} + ${WAIT_FOR})
    >&2 echo "wait from ${start_time} to ${end_time} for update to complete"
    counter=0
	
    while (( $(date +%s) < ${end_time} )); do
	
	    is_complete=$(cf active-deploy-list | grep $WAITING_FOR)
		
		tmp1="in_progress"
		tmp2="complete"
		if [[ "${is_complete/$tmp1}" != "$is_complete" && "${is_complete/$tmp2}" != "$is_complete" ]] ; then
          return 0
        else
          let counter=counter+1		
		  phase=$(cf active-deploy-show ${WAITING_FOR} | grep "^phase:")
		  if [[ -z ${phase} ]]; then
            >&2 echo "ERROR: Update ${WAITING_FOR} not in progress"
            return 2
          fi
		  local str="phase: "
		  echo "=========> phase: "

		  local PHASE=${phase#$str}
		  echo ${PHASE}
		
		  status=$(cf active-deploy-show ${WAITING_FOR} | grep "^status:")
		  if [[ -z ${status} ]]; then
            >&2 echo "ERROR: Update ${WAITING_FOR} not in progress"
            return 2
          fi
		  str="status: "
		  echo "=========> status: "
		
		  local STATUS=${status#$str}
		  echo ${STATUS}
        
          # Echo status only occassionally
          if (( ${counter} > 9 )); then
            >&2 echo "After $(expr $(date +%s) - ${start_time})s phase of ${WAITING_FOR} is ${PHASE} (${STATUS})"
            counter=0
          fi
        
          PHASE_ID=$(phase_id ${PHASE})
        
          if [[ "${STATUS}" == "completed" && "${WAITING_FOR_PHASE}" != "Initial" ]]; then return 0; fi
        
          if [[ "${STATUS}" == "failed" ]]; then return 5; fi
        
          if [[ "${STATUS}" == "aborting" && "${WAITING_FOR_PHASE}" != "Initial" ]]; then return 5; fi
          
          if [[ "${STATUS}" == "aborted" ]]; then
            if [[ "${WAITING_FOR_PHASE}" == "Initial" && "${PHASE}" == "initial" ]]; then return 0
            else return 5; fi
          fi
        
          if [[ "${STATUS}" == "in_progress" ]]; then
            if (( ${PHASE_ID} > ${WAITING_FOR_PHASE_ID} )); then return 0; fi 
          fi
        
          sleep 3
		  
        fi
		
    done
    
    >&2 echo "ERROR: Failed to update group"
    return 3
}

###################################################################################
###################################################################################

if [[ -z ${BACKEND} ]]; then
  echo "ERROR: Backend not specified"
  exit 1
fi

install_cf
cf --version
install_active_deploy

cf plugins
cf active-deploy-service-info

if [ $USER_TEST ]; then
  advance=$(cf active-deploy-advance ${CREATE})
  wait_for_update $CREATE rampdown 120 && rc=$? || rc=$?
  echo "wait result is $rc"
  cf active-deploy-list
  if (( $rc )); then
    echo "ERROR: update failed"
    echo cf-active-deploy-rollback $advance
    wait_for_update $advance initial 300 && rc=$? || rc=$?
    cf active-deploy-delete $advance
    exit 1
  fi
  # Cleanup
  cf active-deploy-delete $advance
else
  cf active-deploy-rollback ${CREATE}
  exit 1
fi
