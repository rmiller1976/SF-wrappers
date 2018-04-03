#!/usr/bin/env bash

set -euo pipefail

########################################################
#
# Run X scans in parallel
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

# Change Log
# v1.01 March 30, 2018 - Add ability to continue when it senses failed scans
#                      - Consolidate reporting of failed volumes
# v1.02 April 3, 2018  - Add delay between scan executions

# Set variables
readonly VERSION="1.02 April 3, 2018"
readonly PROG="${0##*/}"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly STARFISH_BIN_DIR="${SFHOME}/bin"
readonly SF="${STARFISH_BIN_DIR}/client"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"

# Global variables
SFVOLUMES=()
PARALLEL=3
MTIMECHK=0
TARGETSCAN="diff"
EMAIL=""
EMAILFROM=root
EXCL_LIST=()
SKIP_LIST=()
TARGETMTIME=""
NUMMTIME=""
TARGETDIFF=""
NUMDIFF=""
DELAY=10

logprint() {
  echo -e "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Issue!" -a $LOGFILE -r $EMAILFROM $EMAIL
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

usage() {
    local msg="${1:-""}"

    if [ ! -z "${msg}" ]; then
        echo "${msg}" >&2
    fi

    cat <<EOF
Run SF scans in parallel
$VERSION

This script initiates multiple SF volume scans in parallel. NOTE - if a previous scan for a volume failed, the volume may be skipped, depending on what value is set for --mtime. In this situation, either change the value of --mtime, or manually run a scan of the volume.

${PROG} --email <recipients> [options]

  -h, --help          - print this help and exit

Required:
  --email <recipient>		- Email notifcations to <recipients> (comma separated)

Optional:
  --mtime		- Number of mtime scans between diff (0 for all diff)
  --parallel		- Number of concurrent scans (default: 3)
  --exclude <volume>	- Exclude volume from scan
  --from <sender>	- Email sender (default: root)
  --delay <seconds>	- Delay between scan initiations (default: 10)

${PROG} --email bob@company.com --parallel 10 --mtime 5
Run up to 10 volume scans in parallel, looking at the scan 5 scans ago for each volume to determine whether this should be a differential or mtime scan. Email recipient for notifications is bob@company.com

${PROG} --email bob@company.com --mtime 0 --exclude sfvol4 --exclude sfvol5
Run up to 3 volume scans in parallel, looking only at the first (initial) scan for each volume (resulting in all scans being a differential). Exclude volumes sfvol4 and sfvol5 from being scanned.

EOF
exit 1
}

parse_input_parameters() {
  local errorcode
  local volume
  logprint "Parsing input parameters"
  while [[ $# -gt 0 ]]; do
    case $1 in
    "--exclude")
      check_parameters_value "$@"
      shift
      volume=$1
      [[ $volume == *: ]] && volume=${volume::-1}
      EXCL_LIST+=("$volume")
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
      check_parameters_value "$@"
      shift
      MTIMECHK=$1
      ;;            
    "--parallel")
      check_parameters_value "$@"
      shift
      PARALLEL=$1
      ;;
    "--delay")
      check_parameters_value "$@"
      shift
      DELAY=$1
      ;;
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.."
      ;;
    esac
    shift
  done

# Check for required parameters
  if [[ $EMAIL == "" ]]; then
    echo "Required parameter missing. Exiting.."
    logprint "Required parameter missing. Exiting.."
    exit 1
  fi
# Check for optional parameters
  logprint " email from: $EMAILFROM"
  logprint " email recipients: $EMAIL"
  if [[ ${#EXCL_LIST[@]} -eq 0 ]]; then
    logprint " SF volumes: [All]"
  else
    logprint " Volumes to exclude: ${EXCL_LIST[@]}"
  fi
  logprint " mtime scans (0=diff, 1=mtime): $MTIMECHK"
  logprint " parallel scans: $PARALLEL"
  logprint " Delay between scans: $DELAY"
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

determine_scan_list() {
  local allvolumes
  local addvolume
  allvolumes=$(${SF} volume list --format 'vol' --no-headers)
  logprint "List of all volumes: $allvolumes"
# Remove excluded volumes from list
  for volume in $allvolumes 
    do
      addvolume=1
      if [[ ${#EXCL_LIST[@]} > 0 ]]; then
        for excl_volume in "${EXCL_LIST[@]}"
          do
            if [[ $excl_volume == $volume ]]; then
              addvolume=0
            fi
          done
      fi
      if [[ ${addvolume} -eq 1 ]]; then
        SFVOLUMES+=($volume)
      fi
    done
  logprint "List of volumes to be scanned: ${SFVOLUMES[@]}"
}

last_scan() {
  local scantype
# figure out when last diff scan was, and decide whether we run diff or mtime.
  for volume in "${SFVOLUMES[@]}"
    do
      set +e
      scantype=""
      scantype=$(${SF} scan list $volume  -n $MTIMECHK --format="type status" --no-headers | grep -v "ing" | grep "done" | head -1 | cut -f 1 -d" ")
      set -e
        if  [[ "${scantype}" = "diff" ]]; then
      	  TARGETMTIME+=$volume" "
        elif [[ "${scantype}" = "" ]]; then
          SKIP_LIST+=($volume)
        else
          TARGETDIFF+=$volume" "
        fi
    done
  logprint "List of volumes with failed scans detected that will be skipped: ${SKIP_LIST[@]}"
  logprint "Volumes for mtime scan: $TARGETMTIME"
  logprint "Volumes for diff scan: $TARGETDIFF"
}

initiate_scans() {
  NUMMTIME=`echo $TARGETMTIME | wc -w`
set +x
  logprint "NUMMTIME: $NUMMTIME"
  if [ $NUMMTIME -gt 0 ] ; then
    logprint "starting mtime scans on $NUMMTIME volumes"
    echo $TARGETMTIME | xargs  -n1 -P $PARALLEL -d" " -I % sh -c "{ ${SF} scan start % -t mtime --wait >> $LOGFILE; sleep $DELAY; }"
  fi
  NUMDIFF=`echo $TARGETDIFF | wc -w`
  logprint "NUMDIFF: $NUMDIFF"
  if [ $NUMDIFF -gt 0 ] ; then
     logprint "Starting diff scans on $NUMDIFF volumes"
    echo $TARGETDIFF | xargs  -n1 -P $PARALLEL -d" " -I % sh -c "{ ${SF} scan start % -t diff --wait >> $LOGFILE; sleep $DELAY; }"
  fi
  logprint "Scans complete"
}

[[ $# -lt 1 ]] && usage "Not enough arguments";

# if first parameter is -h or --help, call usage routine
if [ $# -gt 0 ]; then
  [[ "$1" == "-h" || "$1" == "--help" ]] && usage
fi

# Check if logdir and logfile exists, and create if it doesnt
[[ ! -e $LOGDIR ]] && mkdir $LOGDIR
[[ ! -e $LOGFILE ]] && touch $LOGFILE
logprint "---------------------------------------------------------------"
logprint "Script executing"
echo "Script starting, in process"

# start script
echo "Step 1: Parse input parameters"
parse_input_parameters $@
echo "Step 1 Complete"
echo "Step 2: Verify prereqs"
check_mailx_exists
echo "Step 2: Mailx verified"
echo "Step 3: Determine scan list"
determine_scan_list
echo "Step 3 Complete"
echo "Step 4: Determine last scan for volumes"
last_scan
echo "Step 4 Complete"
echo "Step 5: Initiate scans"
initiate_scans
echo "Step 5 Complete"
echo "Script complete"
