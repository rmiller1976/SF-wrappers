#!/bin/bash

set -euo pipefail

########################################################
#
# SF tool to mount a snapshot and scan
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
readonly VERSION="1.05 March 2, 2018"
readonly PROG="${0##*/}"
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly REPORTSDIR="reports"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"
readonly MOUNTPATH="/mnt/sf"

# global variables
SFVOLUMENAME=""
HOST=""
SNAP=""
PATHINSNAPSHOT=""
EMAIL=""
EMAILFROM="root"
MOUNT_OUTPUT=""
LATEST_SNAPSHOT=""
FULL_MOUNT_PATH=""
SCANTYPE=" -t diff "
SCANID=""
NFS="vers=3"

logprint() {
  echo -e "$(date +%D-%T): $*" >> $LOGFILE
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

usage() {
  local msg="${1:-""}"
  if [ ! -z "${msg}" ]; then
    echo "${msg}" >&2
  fi
  cat <<EOF

Starfish Snapshot and Mount script 
$VERSION

This script mounts a snapshot to the /mnt/sf location, assigns it to a provided Starfish volume name, performs a Starfish scan, and unmounts the snapshot. Execution logs are kept at $LOGDIR
This has been tested for Isilon snapshots only.

USAGE:
$PROG <SF volume name> --host <hostname:/path> --snap <name> --path <path within snapshot> --email <recipient>

   -h, --help            		- print this help and exit

Required Parameters:
   <SF volume name>    			- Starfish Volume Name that will be assigned to the mounted snapshot
   --host <hostname:/path>		- Hostname and initial path of the snapshot
   --snap <name>			- Name of the snapshot (minus date portion)
   --path <path within snapshot>    	- Path within the snapshot to mount
   --email <recipient>			- Email status to <recipient>

Optional:
   --mtime				- Use mtime scan (default = diff)
   --nfs4				- Use NFS v4 (default=NFS v3)
   --from <sender>			- Send email from <sender> (default=root)

Examples:
$PROG sfvol --host nfsserver.company.com:/ifs/.snapshot --snap Snap_Weekly --path company/Userdata --email bob@company.com

This will mount the latest iteration of the Snap_Weekly snapshot found at nfsserver.company.com:/ifs/.snapshot/*Snap_Weekly*/company/Userdata directory as SF volume 'sfvol' to location /mnt/sf. Status will be sent to bob@company.com

$PROG sfvol --host nfsserver.company.com:/qhome/.snapshot --snap Snap_Weekly --path / --email bob@company.com
This will mount the latest iteration of the Snap_Weekly snapshot found at nfsserver.company.com:/qhome/.snapshot/*Snap_Weekly* directory as SF volume 'sfvol' to location /mnt/sf.


EOF
exit 1
}

check_path_exists () {
if [[ ! -d "$1" ]]; then
  logprint "Directory $1 does not exist, exiting.."
  echo "Directory $1 does not exist. Please create this path and re-run"
  exit 1
else
  logprint "Directory $1 found"
fi
}

parse_input_parameters() {
  logprint "Parsing input parameters"
  SFVOLUMENAME=$1
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
    "--host")
      check_parameters_value "$@"
      shift
      HOST=$1
      ;; 
    "--snap")
      check_parameters_value "$@"
      shift
      SNAP=$1
      ;;
    "--path")
      check_parameters_value "$@"
      shift
      PATHINSNAPSHOT=$1
      ;;
    "--email")
      check_parameters_value "$@"
      shift
      EMAIL=$1
      ;;
    "--mtime")
      SCANTYPE=" -t mtime "
      ;;
    "--nfs4")
      NFS="vers=4"
      ;;
    "--from")
      check_parameters_value "$@"
      shift
      EMAILFROM=$1
      ;; 
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.." 
      ;;
    esac
    shift
  done
  logprint " SF Volume Name: $SFVOLUMENAME"
  logprint " Snapshot host: $HOST"
  logprint " Snapshot name: $SNAP"
  logprint " Path in Snapshot: $PATHINSNAPSHOT"
  logprint " Email: $EMAIL"
  logprint " Email From: $EMAILFROM"
  logprint " Type: $SCANTYPE"
  logprint " Mountpath: $MOUNTPATH"
  logprint " NFS: $NFS"
}

verify_sf_volume() {
  local sf_vol_list_output
  local errorcode
  logprint "Checking if $1 exists in Starfish"
  set +e
  sf_vol_list_output=$(sf volume list | grep $1)
  set -e
  if [[ -z "$sf_vol_list_output" ]]; then
    errorcode="Starfish volume $1 is not a Starfish configured volume."
    logprint "$errorcode"
    echo -e "$errorcode"
    email_alert "$errorcode"
    exit 1
  fi
  logprint "$1 found in Starfish"
}

mount_vol() {
  local errorcode
  local mount_output
  local df_output
  logprint "Checking if a mount at $2 exists.."
  set +e
  df_output=$(df -ak | grep $2)
  set -e
  if [[ -n "$df_output" ]]; then
    errorcode="Mountpoint $2 in use. Check 'sf scan pending' to see if a scan is already running for this mountpoint. Otherwise, clear the mountpoint and run again"
    logprint "$errorcode"
    echo -e "$errorcode"
    email_alert "$errorcode"
    exit 1
  fi
  logprint "No existing mount at $2 exists - mounting $1 to $2"
  set +e
  mount_output="$(mount -t nfs -o $NFS,noatime,defaults $1 $2 2>&1)"
  errorcode=$?
  set -e
  if [[ $errorcode -eq 0 ]]; then
    logprint "Mount of $1 to $2 successful"
  else
    logprint "Mount of $1 to $2 failed with error: $mount_output.\n\r\n\r Exiting.."
    echo -e "Mount of $1 to $2 failed with error: $mount_output.\n\r\n\r Exiting.."
    email_alert "Mount of $1 to $2 failed with the error: $mount_output."
    exit 1
  fi
}

get_latest_snap() {
  logprint "Getting latest snapshot"
  set +e
  LATEST_SNAPSHOT="$(ls -lr $LOCAL_MOUNTPATH/*$SNAP* | tail -n +1 | head -1 | xargs -n 1 basename)"
  set -e
  LATEST_SNAPSHOT=${LATEST_SNAPSHOT::-1}
  logprint "Latest snapshot is $LATEST_SNAPSHOT"
  FULL_MOUNT_PATH="$HOST/$LATEST_SNAPSHOT/$PATHINSNAPSHOT"
  logprint "Fully compiled mount path is: $FULL_MOUNT_PATH"
}

unmount_vol() {
  local errorcode
  local unmount_output
  logprint "Unmounting $1"
  set +e
  unmount_output="$(umount $1 2>&1)"
  errorcode=$?
  set -e
  if [[ $errorcode -eq 0 ]]; then
    logprint "Unmount of $1 successful"
  else
    logprint "Unmount of $1 failed with error: $unmount_output. \n\r\n\r Exiting.."
    echo -e "Unmount of $1 failed with error: $unmount_output. \n\r\n\r Exiting.."
    email_alert "Unmount of $1 failed with error: $unmount_output."
    exit 1
  fi
}
  
initiate_scan() {
  local errorcode
  local scanoutput
  logprint "Starting scan of $1"
  set +e
  scanoutput="$(sf scan start $1 --wait $SCANTYPE 2>&1 | grep "Scan id")"
  errorcode=$?
  set -e
  SCANID=${scanoutput:9}
  if [[ $errorcode -eq 0 ]]; then
    logprint "sf volume scanned successfully. Scan id $SCANID"
  else
    set +e
    logprint "sf volume scan failed with error: $errorcode"
    logprint "Scan status: $(sf scan show $SCANID)"
    logprint "Unmounting $LOCAL_MOUNTPATH and exiting.."
    echo "sf volume scan failed with error: $errorcode"
    echo "Scan status: $(sf scan show $SCANID)"
    echo "Unmounting $LOCAL_MOUNTPATH and exiting.."
    email_alert "sf volume scan failed.  Scan status: $(sf scan show $SCANID)"
    set -e
    unmount_vol $LOCAL_MOUNTPATH
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

# Check that mailx exists
logprint "Checking for mailx"
if [[ $(type -P mailx) == "" ]]; then
   logprint "Mailx not found, exiting.."
   echo "mailx is required for this script. Please install mailx with yum or apt-get and re-run" 2>&1
   exit 1
else
   logprint "Mailx found"
fi

echo "Script starting:"
echo "Step 1: Parse input parameters"
parse_input_parameters $@
echo "Step 1 complete"
LOCAL_MOUNTPATH="$MOUNTPATH/$SFVOLUMENAME"
echo "Step 2: Verify SF volume defined"
verify_sf_volume $SFVOLUMENAME
echo "Step 2 complete"
echo "Step 3: Verify mount path exists"
check_path_exists $LOCAL_MOUNTPATH
echo "Step 3 complete"
echo "Step 4: Perform initial (discovery) mount"
mount_vol $HOST $LOCAL_MOUNTPATH
echo "Step 4 complete"
echo "Step 5: Get latest snapshot"
get_latest_snap
echo "Step 5 complete"
echo "Step 6: Unmount initial (discovery) mount"
unmount_vol $LOCAL_MOUNTPATH
sleep 10
echo "Step 6 complete"
echo "Step 7: Mount full path"
mount_vol $FULL_MOUNT_PATH $LOCAL_MOUNTPATH
echo "Step 7 complete"
echo "Step 8: Start scan. NOTE - this can take a while. Run 'sf scan list' in another window to check progress"
initiate_scan $SFVOLUMENAME
echo "Step 8 complete"
echo "Step 9: Unmount full path"
unmount_vol $LOCAL_MOUNTPATH
echo "step 9 complete"
logprint "Script completed"
email_notify "$(sf scan show $SCANID)"
echo "Script completed"


