#!/bin/bash

set -euo pipefail

########################################################
#
# SF script to remove files
#
########################################################

#********************************************************
#
# Starfish Storage Corporation ("COMPANY") CONFIDENTIAL
# Unpublished Copyright (c) 2011-2018 Starfish Storage Corporation, All Rights Reserved.
#
# NOTICE:  All information contained herein is, and remains the property of COMPANY. The intellectual and
# technical concepts contained herein are proprietary to COMPANY and may be covered by U.S. and Foreign
# Patents, patents in process, and are protected by trade secret or copyright law. Dissemination of this
# information or reproduction of this material is strictly forbidden unless prior written permission is
# obtained from COMPANY.  Access to the source code contained herein is hereby forbidden to anyone except
# current COMPANY employees, managers or contractors who have executed Confidentiality and Non-disclosure
# agreements explicitly covering such access.
#
# ANY REPRODUCTION, COPYING, MODIFICATION, DISTRIBUTION, PUBLIC  PERFORMANCE, OR PUBLIC DISPLAY OF OR
# THROUGH USE  OF THIS  SOURCE CODE  WITHOUT  THE EXPRESS WRITTEN CONSENT OF COMPANY IS STRICTLY PROHIBITED,
# AND IN VIOLATION OF APPLICABLE LAWS AND INTERNATIONAL TREATIES.  THE RECEIPT OR POSSESSION OF  THIS SOURCE
# CODE AND/OR RELATED INFORMATION DOES NOT CONVEY OR IMPLY ANY RIGHTS TO REPRODUCE, DISCLOSE OR DISTRIBUTE
# ITS CONTENTS, OR TO MANUFACTURE, USE, OR SELL ANYTHING THAT IT  MAY DESCRIBE, IN WHOLE OR IN PART.  
#
# FOR U.S. GOVERNMENT CUSTOMERS REGARDING THIS DOCUMENTATION/SOFTWARE
#   These notices shall be marked on any reproduction of this data, in whole or in part.
#   NOTICE: Notwithstanding any other lease or license that may pertain to, or accompany the delivery of,
#   this computer software, the rights of the Government regarding its use, reproduction and disclosure are
#   as set forth in Section 52.227-19 of the FARS Computer Software-Restricted Rights clause.
#   RESTRICTED RIGHTS NOTICE: Use, duplication, or disclosure by the Government is subject to the
#   restrictions as set forth in subparagraph (c)(1)(ii) of the Rights in Technical Data and Computer
#   Software clause at DFARS 52.227-7013.
#
#********************************************************

# Set variables
readonly VERSION="1.0 February 22, 2018"
PROG="${0##*/}"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly SF=${SFHOME}/bin/client
readonly SFREMOVE=${SFHOME}/bin/remove
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"
readonly FILELIST="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW"

# Global variables
SFVOLUME=""
EMAIL=""
EMAILFROM=root
DRYRUN=""
MODIFIER="a"
DAYS_AGO="365"

logprint() {
  echo "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Failed!" -a $LOGFILE -r $EMAILFROM $EMAIL
}

email_notify() {
  (echo -e "$1") | mailx -s "$PROG Completed Successfully" -r $EMAILFROM $EMAIL
}

fatal() {
  local msg="$1"
  echo "${msg}" >&2
  exit 1
}

check_parameters_value() {
  local param="$1"
  [ $# -gt 1 ] || fatal "Missing value for parameter ${param}"
}

usage () {
  local msg="${1:-""}"
  if [ ! -z "${msg}" ]; then
    echo "${msg}" >&2
  fi
  cat <<EOF

Starfish script to remove old data
$VERSION

$PROG <volume> [options] 

   -h, --help              - print this help and exit

Required:
   <volume>	              - Starfish volume to remove data from. Accepts either <volume>, <volume:>, or <volume:path> format
   --email <recipients>	      - Email notifications to <recipients> (comma separated)

Optional:
   --days		      - Remove data older than X days (Default 365)
   --from <sender>	      - Email sender (default: root)
   --mtime		      - Use mtime (default is atime)
   --dry-run		      - Do not actually remove data. Useful to see what files would be rmeoved.


Examples:
$PROG nfs1:/data --dry-run --days 90 --from sysadmin@company.com  --email a@company.com,b@company.com
Run $PROG for SF volume nfs1:/data, in dry run mode, looking to remove files older than 90 days.  Email results to users a@company.com and b@company.com, coming from sysadmin@company.com

EOF
exit 1
}

parse_input_parameters() {
  local errorcode
  logprint "Parsing input parameters"
  SFVOLUME=$1
  shift 
  while [[ $# -gt 0 ]]; do
    case $1 in
    "--dry-run")
      DRYRUN="--dry-run"
      ;;
    "--days")
      check_parameters_value "$@"
      shift
      DAYS_AGO=$1            
      ;;
    "--email")
      check_parameters_value "$@"
      shift
      EMAIL=$1
      ;;
    "--from")
      check_parameters_value "$@"
      shift
      EMAILFROM=$1
      ;;
    "--mtime")
      MODIFIER="m"
      ;;      
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.."
      ;;
    esac
    shift
  done

# Check for required parameters
  if [[ $EMAIL == "" ]] ; then
    echo "Required parameter missing. Exiting.."
    logprint "Required parameter missing. Exiting.."
    exit 1
  fi
  logprint " Volume: $SFVOLUME"
  logprint " Days: $DAYS_AGO"
  logprint " a/mtime: $MODIFIER"
  logprint " Email From: $EMAILFROM"
  logprint " Email: $EMAIL"
  [[ -z $DRYRUN ]] || logprint " Dry run: $DRYRUN"
}

check_mailx_exists() {
  logprint "Checking for mailx"
  if [[ $(type -P mailx) == "" ]]; then
    logprint "Mailx not found, exiting.."
    echo "mailx is required for this script. Please install mailx with yum or apt-get and re-run" 2>&1
   exit 1
  else
    logprint "Mailx found"
  fi
}

run_sf_query() {
  local errorcode
  local joboutput
  OLDER_THAN="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  set +e
  joboutput="$(${SF} query $SFVOLUME --${MODIFIER}time 19000101-$OLDER_THAN --type f -H > ${FILELIST}-1.tmp)"
  errorcode=$?
  set -e
  if [[ $errorcode -eq 0 ]]; then
    logprint "SF query completed successfully"
  else
    logprint "SF query failed with error: $errorcode"
    logprint "SF query output: $joboutput"
    echo "SF query failed with error: $errorcode"
    echo "SF query output: $joboutput"
    email_alert "SF query failed with error: $errorcode."
    exit 1
  fi
}

modify_filelist() {
  set +e
  local volume
  local fullpath
  local cmdtorun

# determine root volume 
  volume=`echo $SFVOLUME | awk -F: '{print $1}'`
  volume=${volume}:
  logprint "root volume: $volume"

# determine full mounted path of SF volume
  fullpath=`sf volume list --csv --no-headers | grep nfs4 | awk -F, '{print $2}'`

# remove leading and trailing " characters, and add trailing /
  fullpath=${fullpath:1:-1}
  fullpath=${fullpath}/
  logprint "full mounted path: $fullpath"
  
# replace root SF volume name with fullpath
  `sed -i "s;$volume;$fullpath;g" ${FILELIST}-1.tmp`

# change \n at the end of every line to \0 so that SF remove can accept input
  `tr '\n' '\0' < ${FILELIST}-1.tmp > ${FILELIST}-2.tmp`
  set -e
}

build_and_run_job_command() {
  local errorcode
  local joboutput
  local jobid
  OLDER_THAN="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  set +e
  logprint "Starting SF job engine"
  joboutput="$(${SF} job start "${SFREMOVE} --from-file ${FILELIST}-2.tmp ${DRYRUN}" "$SFVOLUME" --from-scratch --no-entry-verification --wait 2>&1 | sed -n 1p)"
  errorcode=$?
  set -e
  jobid=`echo "$joboutput" | awk '{print substr($0,length($0)-11,4)}'`
  if [[ $errorcode -eq 0 ]]; then
    logprint "SF job ID $jobid completed successfully"
  else
    set +e
    logprint "SF job failed with error: $errorcode"
    logprint "SF job status: $(sf job show $jobid)"
    echo "SF job failed with error: $errorcode"
    echo "SF job status: $(sf job show $jobid)"
    email_alert "SF job failed. Job status $(sf job show $jobid)"
    set -e
    exit 1
  fi
}

# if first parameter is -h or --help, call usage routine
if [ $# -gt 0 ]; then
  [[ "$1" == "-h" || "$1" == "--help" ]] && usage
fi

# Check if logdir and logfile exists, and create if it doesnt
[[ ! -e $LOGDIR ]] && mkdir $LOGDIR
[[ ! -e $LOGFILE ]] && touch $LOGFILE
logprint "---------------------------------------------------------------"
logprint "Script executing"
logprint "$VERSION"
echo "Script starting, in process"

# start script
echo "Step 1: Parse input parameters"
parse_input_parameters $@
echo "Step 1 Complete"
echo "Step 2: Verify prereq's (mailx)"
check_mailx_exists
echo "Step 2 - mailx verified"
echo "Step 2 Complete"
echo "Step 3: Run SF query command"
run_sf_query
echo "Step 3 Complete"
echo "Step 4: Modify $FILELIST"
modify_filelist
echo "Step 4 Complete"
echo "Step 5: Build and run job command"
build_and_run_job_command
echo "Step 5 Complete"
email_notify "Options specified: $SFVOLUME, use ${MODIFIER}time, files older than $DAYS_AGO days old, $DRYRUN"
echo "Script complete"


