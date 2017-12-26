#!/bin/bash

set -euo pipefail

readonly VERSION=0.9
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly SF="${SFHOME}/bin"
readonly PROG="$0"
readonly LOGDIR="logs"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"

# logprint routine called to write to log file. This log is separate from the one called via the --log option at the command line. That log file is for sending results to a log - this log file is for tracking execution of the script
logprint () {
  echo "$(date +%D-%T): $*" >> $LOGFILE
}

usage() {
  cat <<EOF
Duplicate_check wrapper script
$VERSION

${PROG} [options] <source> <destination>

usage: $PROG [--email AND/OR --log] [options] VOL:PATH [VOL:PATH ...]]

$PROG is a wrapper script that is designed to enhance the user experience of the built-in duplicate_check tool.  $PROG can be called from cron, and it can email or log the results for further analysis. 

NOTE - Either the '--email' and/or '--log' file is required!

The duplicate_check tool that $PROG invokes is designed to calculate the total size of duplicated files.
 It can operate across all starfish volumes or specific volume.
 The calculation is performed over five phases:
 - Find all rows with a unique file size
 - Quick-hash all the candidate duplicates
 - Find entries with non unique quick-hash
 - Calculate a full hash of those entries
 - Find files with same hash

Required:
  --email 		Destination email(s) address (ex. --email "a@a.pl b@b.com")
                        If more than one recipient, then quotes are needed around the emails

         --- AND/OR ---

  --log			Save email contents to a specified file (it must be a path to not existing file in existing directory). 
                        It may contain datatime parts (see 'man date'), for example:
                        --log "/opt/starfish/log/$PROG-%Y%m%d-%H%M%S.log"
                        NOTE: When running from cron, escape the % chars using the following
                        --log "/opt/starfish/log/$PROG-\%Y\%m\%d-\%H\%M\%S.log"

options:
  -h, --help            show this help message and exit
  -v, --verbose         verbose output
  --check-unique-file-size
                        Runs additional step at beginning to run quick hash only on files with non unique size.
                        It may lead to performance gain when there is small number of files with non unique
                        size (for example when --min-size is set to large number like 1G). It may be slower
                        than default approach when number of entries with non unique size is large.
  --min-size SIZE       Minimal file size. Default: 10M
  --resume-from-dir DIR
                        Path to directory with logs from previous execution
  --tmp-dir DIR         Directory used to keep temporary files

Examples:
$PROG --log "/opt/starfish/log/$PROG-%Y%m%d-%H%M%S.log" --check-unique-file-size sfvol:
This will run the duplicate checker, running a quick hash on files located on the sfvol: volumes that have a non unique size. Results will be sent to the "/opt/starfish/log/$PROG-%Y%m%d-%H%M%S.log" file

$PROG --min-size 25M --email "a@a.pl, b@b.com" sfvol1: sfvol2:
This will run the duplicate checker on both sfvol1 and sfvol2 volumes, looking for duplicates with a minimum size of 25M, and emailing the results to users a@a.pl, b@b.com

EOF
  exit 1
}

fatal() {
  echo "$@"
  exit 1
}

# global variables
EMAILS=""
LOG_EMAIL_CONTENT=""
VERBOSE=0
CHECK_UNIQUE_FILE_SIZE=""
JSON="--json"
MIN_SIZE=""
RESUME_FROM_DIR=""
TMP_DIR=""
VOLUMES=""
DUPLICATE_FILE_PATH=""

# Check if logdir and logfile exists, and create if it doesnt
[[ ! -e $LOGDIR ]] && mkdir $LOGDIR
[[ ! -e $LOGFILE ]] && touch $LOGFILE
logprint "---------------------------------------------------------------"
logprint "Script executing"
logprint "Version: $VERSION"

# Check that mailx exists
logprint "Checking for mailx"
if [[ $(type -P mailx) == "" ]]; then
  logprint "Mailx not found, exiting.."
  echo "mailx is required for this script. Please install mailx with yum or apt-get and re-run" 2>&1
  exit 1
else
   logprint "Mailx found"
fi

check_parameters_value() {
  local param="$1"
  [ $# -gt 1 ] || fatal "Missing value for parameter ${param}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
  "-h"|"--help")
    usage
    ;;
  "--email"|"--emails")
    check_parameters_value "$@"
    shift
    EMAILS=($1)
    ;;
  "-v"|"--verbose")
    VERBOSE=1
    ;;
  "--log") 
    check_parameters_value "$@"
    shift
    LOG_EMAIL_CONTENT=$(date +"$1")
    ;;
  "--check-unique-file-size")
    CHECK_UNIQUE_FILE_SIZE="--check-unique-file-size"
    ;;
  "--json")
    JSON="--json"
    ;;
  "--min-size")
    check_parameters_value "$@"
    shift
    MIN_SIZE="--min-size=$1"
    ;;
  "--resume-from-dir")
    check_parameters_value "$@"
    shift
    RESUME_FROM_DIR="--resume-from-dir=$1"
    ;;
  "--tmp-dir")
    check_parameters_value "$@"
    shift
    TMP_DIR="--tmp-dir=$1"
    ;;
  *)
    if [[ ${1:0:1} != "-" ]]; then
      VOLUMES="$VOLUMES $1"
    fi
    ;;
  esac;
  shift
done

if [[ "$EMAILS" == "" ]] && [[ "$LOG_EMAIL_CONTENT" == "" ]]; then
  logprint "Neither email or log was specified, exiting.."
  echo "Neither email or log was specified, exiting.."
  exit 1
fi    


# Report parameter values to logfile
logprint "emails: $EMAILS"
logprint "log email content: $LOG_EMAIL_CONTENT"
logprint "verbose: $VERBOSE"
logprint "check_unique_file_size: $CHECK_UNIQUE_FILE_SIZE"
logprint "json: $JSON"
logprint "min_size: $MIN_SIZE"
logprint "resume_from_dir: $RESUME_FROM_DIR"
logprint "tmp_dir: $TMP_DIR"
logprint "volumes: $VOLUMES"

#Build duplicate_check cmd line
CMD_TO_RUN="${SF}/duplicate_check $CHECK_UNIQUE_FILE_SIZE $JSON $MIN_SIZE $RESUME_FROM_DIR $TMP_DIR $VOLUMES"

# Execute duplicate check command and capture output
CMD_OUTPUT=$($CMD_TO_RUN)
logprint "command to run: $CMD_TO_RUN"

# Parse output
IFS=','
read -ra OUTPUTARRAY <<< "$CMD_OUTPUT"
unset IFS
COUNT=${OUTPUTARRAY[0]:10}
DUPLICATE_FILE=${OUTPUTARRAY[1]:20}
SKIP_COUNT=${OUTPUTARRAY[2]:16}
SIZE_WITH_ORIGINAL_FILE=${OUTPUTARRAY[3]:28}
SIZE=${OUTPUTARRAY[4]:9:${#OUTPUTARRAY[4]}-10}
logprint "Count: $COUNT"
logprint "Duplicates file: $DUPLICATE_FILE"
logprint "Skip Count: $SKIP_COUNT"
logprint "Size with original files: $SIZE_WITH_ORIGINAL_FILE"
logprint "Size: $SIZE"

# Extract path and filename of duplicate files list
IFS='/'
read -ra PATHARRAY <<< "$DUPLICATE_FILE"
unset IFS
PATHARRAYLENGTH=${#PATHARRAY[@]}
FILENAME=${PATHARRAY[$PATHARRAYLENGTH-1]}
for ((i=1; i<($PATHARRAYLENGTH-1); i++))
do
  DUPLICATE_FILE_PATH="$DUPLICATE_FILE_PATH/${PATHARRAY[i]}"
done

# Determine which volumes were scanned, if not specified from cmd line
if [[ $VOLUMES = "" ]]; then
  read -ra VOLUME_ARRAY <<< `cat $DUPLICATE_FILE_PATH/02*`
  for i in "${VOLUME_ARRAY[@]}"
  do
    IFS=':,'
    read -ra TMP_VAR <<< "$i"
    unset IFS
    if [[ ${TMP_VAR[0]} != "volume" ]]; then
      VOLUMES="$VOLUMES ${TMP_VAR[0]}"
    fi
  done
  logprint "Volume(s) not specified, so the following were scanned: $VOLUMES"
fi

SIZEGB=`awk "BEGIN {print ($SIZE/(1024*1024*1024))}"`
SIZEWITHORIGINALGB=`awk "BEGIN {print ($SIZE_WITH_ORIGINAL_FILE/(1024*1024*1024))}"`
SUBJECT="Duplicate check report for Starfish volumes ($VOLUMES) - $COUNT Duplicates, occupying $SIZEGB GB"

BODY="
Duplicate check run at $NOW.

Duplicates found: $COUNT
Files skipped: $SKIP_COUNT
Size with original files: $SIZEWITHORIGINALGB GB
Size of duplicates: $SIZEGB GB

The list of duplicate files can be found at: $DUPLICATE_FILE
"

if [ ! -z "$LOG_EMAIL_CONTENT" ]; then
    echo -e "$SUBJECT" > $LOG_EMAIL_CONTENT
    echo -e "$BODY" >> $LOG_EMAIL_CONTENT
fi

if [ ! -z "$EMAILS" ]; then
    (echo -e "$BODY") | mailx -s "$SUBJECT" -r root $EMAILS
fi










