#!/bin/bash

set -euo pipefail

########################################################
#
# SF wrapper to enhance user experience of built-in duplicate_check tool 
#
########################################################

# Set variables
readonly VERSION="1.02 January 11, 2018"
readonly PROG="${0##*/}"
readonly SFHOME="${SFHOME:-/opt/starfish}"
readonly LOGDIR="$SFHOME/log/${PROG%.*}"
readonly SF="${SFHOME}/bin"
readonly NOW=$(date +"%Y%m%d-%H%M%S")
readonly LOGFILE="${LOGDIR}/$(basename ${BASH_SOURCE[0]} '.sh')-$NOW.log"

# global variables
EMAILS=""
LOG_EMAIL_CONTENT=""
VERBOSE=0
CHECK_UNIQUE_FILE_SIZE=""
JSON="--json"
MIN_SIZE="10M"
RESUME_FROM_DIR=""
TMP_DIR=""
VOLUMES=""
DUPLICATE_FILE_PATH=""

logprint () {
# logprint routine called to write to log file. This log is separate from the one called via the --log option at the command line. That log file is for sending results to a log - this log file is for tracking execution of the script
  echo "$(date +%D-%T): $*" >> $LOGFILE
}

email_alert() {
  (echo -e "$1") | mailx -s "$PROG Failed!" -a $LOGFILE -r root sf-status@starfishstorage.com,$EMAILS
}

email_notify() {
  (echo -e "$1") | mailx -s "$PROG Completed Successfully" -r root $EMAILS
}

fatal() {
  echo "$@"
  exit 1
}

check_parameters_value() {
  local param="$1"
  [ $# -gt 1 ] || fatal "Missing value for parameter ${param}"
}

usage() {
  cat <<EOF

Duplicate_check wrapper script
$VERSION

This script is a wrapper that is designed to enhance the user experience of the built-in duplicate_check tool.  This script can be called from cron, and it can email or log the results for further analysis. Execution log can be found at $LOGDIR

The duplicate_check tool that $PROG invokes is designed to calculate the total size of duplicated files.
It can operate across all starfish volumes or specific volume.
The calculation is performed over five phases:
 - Find all rows with a unique file size
 - Quick-hash all the candidate duplicates
 - Find entries with non unique quick-hash
 - Calculate a full hash of those entries
 - Find files with same hash

USAGE:
$PROG [--email AND/OR --log] [options] VOL:PATH [VOL:PATH ...]]

NOTE - One or both of the '--email' and '--log' options is required!

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
$PROG --log "/opt/starfish/log/${PROG%.*}-%Y%m%d-%H%M%S.log" --check-unique-file-size sfvol:
This will run the duplicate checker, running a quick hash on files located on the sfvol: volumes that have a non unique size. Results will be sent to the "/opt/starfish/log/${PROG%.*}-%Y%m%d-%H%M%S.log" file

$PROG --min-size 25M --email "a@a.pl, b@b.com" sfvol1: sfvol2:
This will run the duplicate checker on both sfvol1 and sfvol2 volumes, looking for duplicates with a minimum size of 25M, and emailing the results to users a@a.pl, b@b.com
 
$PROG --email "user@company.com"
This will run the duplicate checker on all Starfish volumes, emailing results to user@company.com.


EOF
  exit 1
}

parse_input_parameters() {
  while [[ $# -gt 0 ]]; do
    case $1 in
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
      MIN_SIZE="$1"
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
  logprint "emails: $EMAILS"
  logprint "log email content: $LOG_EMAIL_CONTENT"
  logprint "verbose: $VERBOSE"
  logprint "check_unique_file_size: $CHECK_UNIQUE_FILE_SIZE"
  logprint "json: $JSON"
  logprint "min_size: $MIN_SIZE"
  logprint "resume_from_dir: $RESUME_FROM_DIR"
  logprint "tmp_dir: $TMP_DIR"
  logprint "volumes: $VOLUMES"
}

verify_required_params() {
if [[ "$EMAILS" == "" ]] && [[ "$LOG_EMAIL_CONTENT" == "" ]]; then
  logprint "Neither email or log was specified, exiting.."
  echo "Neither email or log was specified, exiting.."
  usage
  exit 1
fi    
}

build_cmd_line() {
  MIN_SIZE_CMD="--min-size=$MIN_SIZE"
  CMD_TO_RUN="${SF}/duplicate_check $CHECK_UNIQUE_FILE_SIZE $JSON $MIN_SIZE_CMD $RESUME_FROM_DIR $TMP_DIR $VOLUMES"
  logprint "command to run: $CMD_TO_RUN"
}

run_duplicate_check() {
  STARTTIME=$(date +"%H:%M:%S %m/%d/%Y")
  set +e
  CMD_OUTPUT=$($CMD_TO_RUN)
  if [[ $? -ne 0 ]]; then
    echo "duplicate_check command returned an error. Verify syntax of $PROG and run again"
    logprint "duplicate_check command returned an error. Verify syntax of $PROG and run again"
    email_alert "duplicate_check command returned an error. Verify syntax of $PROG and run again"
    exit 1
  fi
  set -e
  ENDTIME=$(date +"%H:%M:%S %m/%d/%Y")
}

parse_output(){
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
}

extract_path_and_filename() {
  IFS='/'
  read -ra PATHARRAY <<< "$DUPLICATE_FILE"
  unset IFS
  PATHARRAYLENGTH=${#PATHARRAY[@]}
  FILENAME=${PATHARRAY[$PATHARRAYLENGTH-1]}
  for ((i=1; i<($PATHARRAYLENGTH-1); i++))
  do
    DUPLICATE_FILE_PATH="$DUPLICATE_FILE_PATH/${PATHARRAY[i]}"
  done
}

determine_scanned_volumes() {
  if [[ $VOLUMES = "" ]]; then
    local volume_array
    local tmp_var
    read -ra volume_array <<< `cat $DUPLICATE_FILE_PATH/02*`
    for i in "${volume_array[@]}"
    do
      IFS=','
      read -ra tmp_var <<< "$i"
      unset IFS
      if [[ ${tmp_var[0]} != "volume" ]]; then
        VOLUMES="$VOLUMES ${tmp_var[0]}"
      fi
    done
    logprint "Volume(s) not specified, so the following were scanned: $VOLUMES"
  fi
}

generate_email_content() {
  local total_files
  local total_size
  local sizegb
  local sizewithoriginalgb
  local percent_dup_size
  local percent_dup_count
  local subject
  local body
  local vol_files
  local vol_size
  logprint "Generating email/log content"
  read -a volume_array <<< "$VOLUMES"
  for i in "${volume_array[@]}"
  do
    vol_files=`sf query $i -H --format "rec_aggrs.files" --maxdepth=0`
    vol_size=`sf query $i -H --format "rec_aggrs.size" --maxdepth=0`
    total_files=$((total_files+vol_files))
    total_size=$((total_size+vol_size))
  done
  sizegb=`awk "BEGIN {print ($SIZE/(1024*1024*1024))}"`
  sizewithoriginalgb=`awk "BEGIN {print ($SIZE_WITH_ORIGINAL_FILE/(1024*1024*1024))}"`
  percent_dup_size=`awk "BEGIN {print ($SIZE * 100 / $total_size)}"`
  percent_dup_count=`awk "BEGIN {print ($COUNT * 100 / $total_files)}"`
  SUBJECT="Duplicate check report for Starfish volumes ($VOLUMES) - $COUNT Duplicates over $MIN_SIZE, occupying $sizegb GB"
  BODY="
Duplicate check started at $STARTTIME, and took $SECONDS seconds to finish. 

- $total_files files were scanned.
- There were $COUNT duplicate files found on volumes ($VOLUMES ) that were over $MIN_SIZE, and those duplicates occupy $sizegb GB of space.
- The size of the duplicates plus their original files is $sizewithoriginalgb GB.
- Duplicates over $MIN_SIZE occupy $percent_dup_count% of the total file count, and occupy $percent_dup_size% of the total file size within $VOLUMES

The list of duplicate files can be found at: $DUPLICATE_FILE
"
  if [ -n "$LOG_EMAIL_CONTENT" ]; then
    logprint "Writing output to logfile"
    echo -e "$SUBJECT" > $LOG_EMAIL_CONTENT
    echo -e "$BODY" >> $LOG_EMAIL_CONTENT
  fi

  if [ -n "$EMAILS" ]; then
    logprint "Emailing results to $EMAILS"
    (echo -e "$BODY") | mailx -s "$SUBJECT" -r root $EMAILS
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

parse_input_parameters $@
verify_required_params
build_cmd_line
run_duplicate_check
parse_output
extract_path_and_filename
determine_scanned_volumes
generate_email_content






