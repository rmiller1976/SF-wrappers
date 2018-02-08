#!/bin/bash

set -euo pipefail

###############################################
#
# SF tool that performs data copy/move/delete.
# Uses sf job engine combined with rsync_wrapper to copy/move/delete data
#
###############################################

# Set variables
readonly VERSION="1.01 February 8, 2018"
readonly PROG="${0##*/}"
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"
readonly STARFISH_BIN_DIR="${SFHOME}/bin"
readonly SF="${STARFISH_BIN_DIR}/client"
readonly SF_RSYNC="${STARFISH_BIN_DIR}/rsync_wrapper"
readonly SF_TAR="${STARFISH_BIN_DIR}/tar_wrapper"

# global variables
EMAIL=""
EMAILFROM="root"
MANIFEST_DIR_FLAG=""
EXTS=""
MINSIZE=""
MAXSIZE=""
SIZERANGE=""
MOVE_SRC_FILES=""
MIGRATE_SRC_OPTIONS=""
MODIFIER="a"
DAYS_AGO="30"
SFJOBOPTIONS=""
DRYRUN=0
RSYNC_CMD=""
TAR=0

logprint() {
  echo -e "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Failed!" -a $LOGFILE -r $EMAILFROM sf-status@starfishstorage.com,$EMAIL
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

check_volume_path() {
  local vol_path="$1"
  if [[ ! "${vol_path}" =~ ":" ]]; then
    fatal "Volume should be passed as <volume>:<path> (but is: ${vol_path})"
  fi
}

get_volume_mount() {
  local vol="$1"
  ${SF} volume show "${vol}" --format "humanized_mounts"
}

check_path_exists() {
if [[ ! -d "$1" ]]; then
  logprint "Directory $1 does not exist, exiting.."
  echo "Directory $1 does not exist. Please create this path and re-run"
  exit 1
else
  logprint "Directory $1 found"
fi
}

usage() {
  local msg="${1:-""}"
  if [ ! -z "${msg}" ]; then
    echo "${msg}" >&2
  fi
  cat <<EOF

Starfish copy/move/delete script
$VERSION

This script is a wrapper that invokes the SF job engine to copy/move/delete data using rsync_wrapper by default, or optionally the tar_wrapper

USAGE:
${PROG} <source volume>:<source path> <destination volume>:<destination path> [options]

  -h, --help          - print this help and exit

Require Parameters:
  <source volume>:<source path> 		- Source volume and path to archive
  <destination volume>:<destination path>	- Destination volume and path

Optional (rsync_wrapper only):
  --days [int]           - files older than this will be copied, based on midnight. Default = 30 days.
  --mtime                - use file modification time for --days. Default = atime.
  --ext  [extension]     - only files that match this extension, if more than one, use "--ext bam --ext fastq"
  --migrate              - remove files from source after copy  (default = no)
  --minsize [size]       - only files larger than this size (e.g. 100M or 10G). Default = 100M
  --maxsize [size]	 - only files smaller than this size (e.g. 100M or 10G). Default = 100P
           NOTE: minsize and maxsize cannot be used together!

Optional (tar only):
  --tar			 - create a tar file in the destination directory of the files processed. 

Optional (rsync or tar):
  --email <recipients>   - Recipient(s) for reports/alerts. Comma separated list.
  --from <sender>	 - Email sender (default: root)
  --from-scratch	 - Run job as if from scratch (do not track internally)
  --job-name <jobname>   - Specify a job name for the SF job
  --dryrun		 - Do not execute the sf job command (useful for verifying command that will be run)

Examples:
$PROG nfs3:1 nfs4: --email user@company.com
Runs an rsync, copying data older than 30 days between the size range of 100M and 100P from nfs3:1 to nfs4. Email user@company.com with error during job execution

$PROG nfs3:1 nfs4: --days 0 --minsize 0b 
Runs an rsync, copying all data up to midnight last night between the size range of 0b and 100P from nfs3:1 to nfs4.

$PROG nfs3:1 nfs4: --days -1 --minsize 50k
Runs an rsync, copying all data (even data past midnight last night) between the size range of 50k and 100P from nfs3:1 to nfs4.

EOF
  exit 1
}

parse_input_parameters() {
  logprint "Parsing input parameters"
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
    "--email")
      check_parameters_value "$@"
      shift
      EMAIL="$EMAIL,$1"
      ;;
    "--from")
      check_parameters_value "$@"
      shift
      EMAILFROM=$1
      ;;
    "--mtime")
      MODIFIER="m"
      ;;
    "--migrate")
      MOVE_SRC_FILES="--remove-source-files"
      MIGRATE_SRC_OPTIONS="--no-entry-verification"
      ;;
    "--days")
      check_parameters_value "$@"
      shift
      DAYS_AGO="$1"
      if [[ "${DAYS_AGO}" -lt -1 ]]; then
        fatal "--days must be -1 or greater! (but is: ${DAYS_AGO})"
      fi
      ;;
    "--ext")
      check_parameters_value "$@"
      shift
      EXTS="${EXTS} --ext $1"
      ;;
    "--minsize")
      check_parameters_value "$@"
      shift
      MINSIZE="$1"
      ;;
    "--maxsize")
      check_parameters_value "$@"
      shift
      MAXSIZE="$1"
      ;;
    "--from-scratch")
      SFJOBOPTIONS="$SFJOBOPTIONS --from-scratch"
      ;;
    "--job-name")
      check_parameters_value "$@"
      shift
      SFJOBOPTIONS="$SFJOBOPTIONS --job-name $1"
      ;;
    "--dryrun")
      DRYRUN=1
      ;;
    "--tar")
      TAR=1
      ;;
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.."
      ;;
    esac
    shift
  done
  if [[ $MINSIZE != "" ]] && [[ $MAXSIZE != "" ]]; then
    logprint "Both minsize and maxsize specified. Exiting.."
    fatal "Both minsize and maxsize specified. Exiting.."
  elif [[ $MINSIZE == "" ]] && [[ $MAXSIZE == "" ]]; then
    SIZERANGE="--size 100M-100P"
  elif [[ $MINSIZE == "" ]]; then
    SIZERANGE="--size 0B-$MAXSIZE"
  elif [[ $MAXSIZE == "" ]]; then
    SIZERANGE="--size $MINSIZE-100P"
  fi
  logprint " Modifier: $MODIFIER"
  logprint " Migrate Options: $MOVE_SRC_FILES"
  logprint " Days: $DAYS_AGO"
  logprint " Exts: $EXTS"
  logprint " Size: $SIZERANGE"
  logprint " Email: $EMAIL"
  logprint " Tar: $TAR (if 1, values for Exts, Size, Days, Modifier, and migrate are ignored)"
  logprint " Dryrun: $DRYRUN"
  if [[ "$SFJOBOPTIONS" != "" ]]; then
    logprint "SF job options: $SFJOBOPTIONS"
  fi
}

build_and_run_cmd_line() {
# This script builds and runs the command to be executed in one step. Breaking it up into multiple
# steps and executing via $(command) command substitution resulted in parameters meant for
# rsync_wrapper (ie, -migrate) to be interpreted as being for the job engine, which caused the
# script to error out. 

  local rsync_or_tar
  local cmd_options
  local errorcode
  local joboutput
  local jobid
  if [[ $TAR -eq 0 ]]; then
    TIME="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
    TIME_OPT="--${MODIFIER}time 19000101-${TIME}"
    rsync_or_tar="${SF_RSYNC} ${MOVE_SRC_FILES}"
    cmd_options="${EXTS} ${SIZERANGE} ${TIME_OPT} ${MIGRATE_SRC_OPTIONS}"
  elif [[ $TAR -eq 1 ]]; then
    rsync_or_tar="${SF_TAR}"
    cmd_options=""
  fi
  if [[ $DRYRUN -eq 0 ]]; then
    set +e 
    logprint "Starting SF job engine"
    joboutput="$(${SF} job start "${rsync_or_tar}" ${SRC_VOL_WITH_PATH} ${DST_VOL_WITH_PATH} ${SFJOBOPTIONS} --wait ${cmd_options} 2>&1 | sed -n 1p)"
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
  fi
}

[[ $# -lt 2 ]] && usage "Not enough arguments"

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

echo "Script starting"
echo "Step 1: Check source volume path"
check_volume_path "$1"
SRC_VOL_WITH_PATH="$1"
logprint "Source Volume & Path: $SRC_VOL_WITH_PATH"
SRC_VOL="${SRC_VOL_WITH_PATH%%:*}"
SRC_PATH="${SRC_VOL_WITH_PATH#*:}"
echo "Step 1 complete"
shift
echo "Step 2: Check destination volume path"
check_volume_path "$1"
DST_VOL_WITH_PATH="$1"
logprint "Destination Volume & Path: $DST_VOL_WITH_PATH"
DST_VOL="${DST_VOL_WITH_PATH%%:*}"
DST_PATH="${DST_VOL_WITH_PATH#*:}"
echo "Step 2 complete"
echo "Step 3: Parse remaining input parameters"
parse_input_parameters $@
echo "Step 3 complete"
echo "Step 4: Get path to the source volume"
SRCROOT="$(get_volume_mount "${SRC_VOL}")"
echo "Step 4 complete"
echo "Step 5: Build and run command line"
build_and_run_cmd_line
echo "Step 5 Complete"
exit 1


