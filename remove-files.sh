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
readonly VERSION="1.0 March 26, 2018"
readonly PROG="${0##*/}"
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
LOWMARK=""
HIGHMARK=""
PCENTUSED=""
AGEONLY="0"
EXCLUDELIST=""
ONEPERCENT=""
TOREMOVE=""

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

This script removes old files from a specified SF volume. 
There are two modes of operation: 
  1) Using the --days option without watermarks. In this mode, all data older than the specified value for --days is removed in the specified volume:path.
  2) Using the --days option with watermarks. In this mode, only data older than the specified value for --days is considered for removal in the specified volume:path, subject to the watermark values. Watermarks are based on overall % volume used, even if the SF volume is specified as volume:path 

$PROG <volume> [options] 

   -h, --help              - print this help and exit

Required:
   <volume>	              - Starfish volume to remove data from. Accepts <volume:path> format
   --email <recipients>	      - Email notifications to <recipients> (comma separated)

Optional:
   --days		      - Remove data older than X days (Default 365)
   --from <sender>	      - Email sender (default: root)
   --mtime		      - Use mtime (default is atime)
   --dry-run		      - Do not actually remove data. Useful to see what files would be rmeoved.
   --low <#>		      - Specify a low water mark for % volume used (between 0 and 1000)
   --high <#>		      - Specify a high water mark for % volume used (between 0 and 100)
   --exclude <filename>	      - Specify an exclusion list

Examples:
$PROG nfs1:/data --dry-run --days 90 --from sysadmin@company.com  --email a@company.com,b@company.com
Run $PROG for SF volume nfs1:/data, in dry run mode, looking to remove files older than 90 days.  Email results to users a@company.com and b@company.com, coming from sysadmin@company.com

$PROG nfs1:/data --days 90 --low 80 --high 85 --email a@company.com --mtime
Run $PROG for SF volume nfs1, removing data based on mtime from nfs1:/data that is at least 90 days old, so long as the volume is at least 85% full. Remove data until volume is down to 80% full. Email notifications to a@company.com

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
    "--high")
      check_parameters_value "$@"
      shift
      HIGHMARK=$1
      ;;
    "--low")
      check_parameters_value "$@"
      shift
      LOWMARK=$1
      ;;
    "--exclude")
      check_parameters_value "$@"
      shift
      EXCLUDELIST=$1
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
  if [[ -z "$HIGHMARK" ]] && [[ -z "$LOWMARK" ]]; then
    logprint "Neither highmark nor lowmark set. Purging data based on age only"
    AGEONLY="1"
  else
    if [[ -n "$HIGHMARK" && -n "$LOWMARK" ]]; then
      logprint "Purging data based on age and watermarks"
      logprint " High watermark set to: $HIGHMARK"
      logprint " Low watermark set to: $LOWMARK"
    else
      logprint "Both watermarks must be set if one is set. Exiting.."
      echo "Both watermarks must be set if one is set. Exiting.."
      exit 1
    fi
  fi
  if [[ -n $EXCLUDELIST ]]; then
    logprint " Exclusion list: $EXCLUDELIST"
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

remove_exclusions() {
  logprint " Removing exclusions specified in $1 from $2"
  while read line_from_exclusion_file; do
    sed -i "\:$line_from_exclusion_file:d" $2
  done < $1
}

format_json_output() {
  local volume
  local fullpath
# Determine volume name
  volume=`head -n 1 < $1 | awk -F, '{print $1}'`
  logprint "  root volume: $volume"
# Determine full path of files
  fullpath=`sf volume list --csv --no-headers | grep $volume | awk -F, '{print $2}'`
  logprint "  full path: $fullpath"
# Remove leading and trailing "
  fullpath=${fullpath:1:-1}
  logprint "  full mounted path: $fullpath"
  sed -i "s;$volume;$fullpath;g" $1
  logprint "  Replaced $volume with $fullpath in $1"
  awk -F, '{print $1"/"$2"/"$3","$4}' < $1 > $2
} 

tally_size() {
  local totaltally
  local size
  totaltally=0
  size=0
  set +e
  while [[ $totaltally -lt $TOREMOVE && (-s $1) ]]; do
# Obtain size of next file from input file ($1)
    size=$(awk -F, '{print $2}' < $1 | head -n 1)
# Copy top line from input file ($1) to tmp output file, and remove line from input file ($1)
    head -1 $1 >> ${FILELIST}-tally.tmp && sed -i '1,1d' $1
# Copy volume, path, and fn from tmp file, and print to output file ($2) 
    awk -F, '{print $1}' < ${FILELIST}-tally.tmp > $2 
    totaltally=$(($totaltally + $size))  
  done
# Remove tally tmp file
  rm ${FILELIST}-tally.tmp
  logprint "Total data being send to job engine for deletion: $totaltally Bytes"
set -e
}

run_sf_query() {
  local errorcode
  local joboutput
  OLDER_THAN="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  set +e
  joboutput="$(${SF} query $SFVOLUME --${MODIFIER}time 19000101-$OLDER_THAN --type f -H -d, --format "${MODIFIER}t volume path fn size" > ${FILELIST}-raw.tmp)"
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

format_results() {
# passing in $AGEONLY
  logprint "Formatting results:"
  logprint " Sorting results"
  sort ${FILELIST}-raw.tmp > ${FILELIST}-1-sorted.tmp
#  rm ${FILELIST}-raw.tmp
  logprint " Removing ${MODIFIER}time values from file"
  sed 's/^[^,]*,//g' < ${FILELIST}-1-sorted.tmp > ${FILELIST}-2-notime.tmp
# format json output converts from json output ("vol","path","fn") to something we can almost use (/volume/path/fn,size)
  logprint " Formatting JSON output:"
  format_json_output ${FILELIST}-2-notime.tmp ${FILELIST}-3-formatted.tmp
#remove exclusions
  if [[ -n $EXCLUDELIST ]]; then
    remove_exclusions $EXCLUDELIST ${FILELIST}-3-formatted.tmp
  fi
# Determine whether further processing is based on age, or age + watermarks
  if [[ $1 = "0" ]]; then
    logprint "Processing query based on age and watermarks"
  elif [[ $1 = "1" ]]; then
    logprint "Processing query based on age only:"
# set $TOREMOVE to very large value (1 Pb) since we don't have a limit when removing by age only
    TOREMOVE=1000000000000000
  fi
# tally_size {inputfile} {outputfile} returns output file in /volume/path/fn format
  tally_size ${FILELIST}-3-formatted.tmp ${FILELIST}-4-tallied.tmp
# change \n at the end of every line to \0 so that SF remove can accept input
# Temporarily set IFS to pipe (|) so that spaces can be accomodated in filenames.
  IFS='|'
  tr '\n' '\0' < ${FILELIST}-4-tallied.tmp > ${FILELIST}-5-final.tmp
  logprint "Replaced \n at end of lines with \0"
  unset IFS
}

determine_root_volume() {
  local _volume
  _volume=`echo $1 | awk -F: '{print $1}'`
  echo ${_volume}
}

build_and_run_job_command() {
  local errorcode
  local joboutput
  local jobid
  OLDER_THAN="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  set +e
  logprint "Starting SF job engine"
  joboutput="$(${SF} job start "${SFREMOVE} --from-file $1 ${DRYRUN}" "$SFVOLUME" --from-scratch --no-entry-verification --wait 2>&1 | sed -n 1p)"
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

determine_percent_full() {
  local cmd_output
  local errorcode
  set +e
  cmd_output="$(df -h --output=source,pcent | grep $(determine_root_volume $1) | sed 's/ \+/ /g' | cut -f2 -d" " | sed 's/%$//')"
  errorcode=$?
  if [[ $errorcode -eq 0 ]]; then
    logprint "df command executed"
  else
    logprint "df command execution failure.  Exiting.."
    echo -e "df command execution failure. Exiting.."
    email_alert "df command execution failure. Exiting.."
    exit 1
  fi
  set -e
  echo $cmd_output
}

determine_one_percent() {
  local cmd_output
  local errorcode
  local one_percent
  set +e
  cmd_output="$(df -B1 --output=source,size | grep $(determine_root_volume $1) | sed 's/ \+/ /g' | cut -f2 -d" " | sed 's/$//')"
  set -e
  echo $((cmd_output / 100))
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
if [[ $AGEONLY == "0" ]]; then
  echo "Step 3b: Determine volume percent full"
  PCENTUSED=$(determine_percent_full $SFVOLUME)
  logprint "Volume $(determine_root_volume $SFVOLUME) percent used: $PCENTUSED"
  echo "Step 3b Complete"
  if [[ $PCENTUSED -gt $HIGHMARK ]]; then
    ONEPERCENT=$(determine_one_percent $SFVOLUME)
    TOREMOVE=$(((PCENTUSED - LOWMARK)*ONEPERCENT))
    logprint "One percent of volume = $ONEPERCENT B. Need to remove $TOREMOVE B"
  else
    logprint "High watermark not reached - not removing any files. Script exiting.."
    echo "High watermark not reached - not removing any files.  Script exiting.."
    exit 1
  fi
fi
echo "Step 3 Complete"
echo "Step 4: Format Results"
format_results $AGEONLY
echo "Step 4 Complete"
echo "Step 5: Build and run job command"
#build_and_run_job_command ${FILELIST}-5-final.tmp
echo "Step 5 Complete"
email_notify "Options specified: $SFVOLUME, use ${MODIFIER}time, files older than $DAYS_AGO days old, $DRYRUN"
echo "Script complete"
echo "NOTE: A new SF scan should be run prior to running this script again!"



