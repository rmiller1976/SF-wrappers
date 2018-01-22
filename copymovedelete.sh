#!/bin/bash

set -euo pipefail

###############################################
#
# SF tool that performs data copy/move/delete.
# Uses sf job engine combined with rsync_wrapper to copy/move/delete data
#
###############################################

# Set variables
readonly VERSION="1.00 January 22, 2018"
readonly PROG="${0##*/}"
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"
readonly STARFISH_BIN_DIR="${SFHOME}/bin"
readonly SF="${STARFISH_BIN_DIR}/client"
readonly SF_RSYNC="${STARFISH_BIN_DIR}/rsync_wrapper"

# global variables
EMAIL="sf-status@starfishstorage.com"
#EMAIL=""
MANIFEST_DIR_FLAG=""
WAIT_OPT=""
EXTS=""
SIZE=""
MOVE_SRC_FILES=""
MIGRATE_SRC_OPTIONS=""
MANIFEST_PER_DIR=""
MANIFEST_DIR="${TMPDIR:-/tmp}"
MODIFIER="a"
# workaround as the date is treated as midnight - i.e. files modified today after midnight wouldn't be processed
DAYS_AGO="-1"
SFJOBOPTIONS=""
DRYRUN=0
RSYNC_CMD=""

logprint() {
  echo -e "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Failed!" -a $LOGFILE -r root $EMAIL
}

email_notify() {
  (echo -e "$1") | mailx -s "$PROG Completed Successfully" -r root $EMAIL
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

This script is a wrapper that invokes the SF job engine to copy/move/delete data using rsync_wrapper.

USAGE:
${PROG} <source volume>:<source path> <destination volume>:<destination path> [options]

  -h, --help          - print this help and exit

Require Parameters:
  <source volume>:<source path> 		- Source volume and path to archive
  <destination volume>:<destination path>	- Destination volume and path

Optional:
  --days [int]           - files older than this will be archived. Default = 30 days.
  --mtime                - use file modification time for --days. Default = atime.
  --ext  [extension]     - only archive this extension, if more than one, use "--ext bam --ext fastq"
  --size [size]          - archive files larger than this size (e.g. 100M or 10G). Default = 100M
  --manifest-dir         - place a manifest of files moved in directory
  --manifest-per-dir     - place a manifest in each directory from which files were archived (in .sf-manifest.archive)
  --migrate              - remove files from source after copy 
  --wait                 - wait until job is complete
  --email <recipients>   - Recipient(s) for reports/alerts. Comma separated.
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
      [ "${DAYS_AGO}" -gt 0 ] || fatal "--days must be greater then zero! (but is: ${DAYS_AGO})"
      ;;
    "--ext")
      check_parameters_value "$@"
      shift
      EXTS="${EXTS} --ext $1"
      ;;
    "--size")
      check_parameters_value "$@"
      shift
      SIZE="--size $1-100P"
      ;;
    "--manifest-dir")
      check_parameters_value "$@"
      shift
      MANIFEST_DIR_FLAG=1
      MANIFEST_DIR="$1"
      [ ! -d "${MANIFEST_DIR}" ] && mkdir "${MANIFEST_DIR}"
      ;;
    "--manifest-per-dir")
      MANIFEST_PER_DIR=1
      ;;
    "--wait")
      WAIT_OPT="--wait"
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
    *)
      logprint "input parameter: $1 unknown. Exiting.."
      fatal "input parameter: $1 unknown. Exiting.."
      ;;
    esac
    shift
  done
  logprint " Modifier: $MODIFIER"
  logprint " Migrate Options: $MOVE_SRC_FILES"
  logprint " Days: $DAYS_AGO"
  logprint " Exts: $EXTS"
  logprint " Size: $SIZE"
  logprint " Manifest Dir Flag: $MANIFEST_DIR_FLAG"
  logprint " Manifest Directory: $MANIFEST_DIR"
  logprint " Manifest per dir: $MANIFEST_PER_DIR"
  logprint " Wait Option: $WAIT_OPT"
  logprint " Email: $EMAIL"
  if [[ "$SFJOBOPTIONS" != "" ]]; then
    logprint "SF job options: $SFJOBOPTIONS"
  fi
}

build_cmd_line() {
  TIME="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  TIME_OPT="--${MODIFIER}time 19000101-${TIME}"
  CMD_TO_RUN="${SF} job start ${SF_RSYNC} ${SRC_VOL_WITH_PATH} ${DST_VOL_WITH_PATH} ${SFJOBOPTIONS} ${EXTS} ${SIZE} ${TIME_OPT} ${WAIT_OPT} ${MIGRATE_SRC_OPTIONS}"
  logprint "command to run: $CMD_TO_RUN"
}

run_sfjob_cmd() { 
  local errorcode
  if [[ $DRYRUN -eq 0 ]]; then
    set +e 
    echo "running command: $CMD_TO_RUN"
 set -x
    CMD_OUTPUT=$($CMD_TO_RUN 2>&1)
 set +x
    errorcode=$?
    set -e
    if [[ $errorcode -ne 0 ]]; then
      echo -e "sf job command failed. Output follows: $CMD_OUTPUT"
      logprint "sf job command failed. Output follows: $CMD_OUTPUT"
      email_alert "sf job command failed. Output follows: $CMD_OUTPUT"
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
echo "Step 5: Build command line"
build_cmd_line
echo "Step 5 complete"
echo "Step 6: Execute sf job command"
run_sfjob_cmd
echo "Step 6 Complete"
exit 1

if [ ! -z "${MANIFEST_DIR_FLAG}" ] ; then
  ${SF} query --csv --escape-paths --no-headers > "${MANIFEST_DIR}/${arc_tag}"
fi

# Output data as src, dst, date
if [ ! -z "${manifest_per_dir}" ] ; then
    dstroot="$(get_volume_mount "${dst_vol}")"
    ${SF} query --csv --escape-paths --no-headers --tag-explicit "${arc_tag}" | while read line ; do
        man_dir="$(echo "${line}" | cut -f 11 | sed -e 's/\"//g' | xargs dirname)"
        echo "${srcroot}/${src_path}, ${dstroot}/${dst_path}, ${arc_date}" >> "${srcroot}/${man_dir}/.sf-manifest.archive"
    done
fi

