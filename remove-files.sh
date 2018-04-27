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

# Change Log
# 1.0 (March 26, 2018) - Original version
# 1.01 (March 27, 2018) - Update tally_size to use awk instead of sed -i
#                       - Add info to final email including where to find files fed to SF job engine,
#                         and how much data was deleted
# 1.02 (April 6, 2018)  - Update usage
#                       - Add more comments into script
#                       - Add ability to use latest of a/c/mtime 
#                       - Add check that sf query -raw.tmp file has data
#                       - Update AWK in tally routine to make more efficient
# 1.03 (April 9, 2018)  - Add in EXCLGROUP parameter to exclude files belonging to group

# Set variables
readonly VERSION="1.03 April 9, 2018"
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
MODIFIER="amc"
DAYS_AGO="365"
LOWMARK=""
HIGHMARK=""
PCENTUSED=""
AGEONLY="0"
EXCLUDELIST=""
EXCLGROUP=""
ONEPERCENT=""
# Set TOREMOVE to 10 Pb
TOREMOVE="10000000000000000"

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
  1) Using the --days option without watermarks. In this mode, all data older than the specified value for --days is removed in the specified volume:path. Up to a maximum of $TOREMOVE bytes of data will be removed.
  2) Using the --days option with watermarks. In this mode, only data older than the specified value for --days is considered for removal in the specified volume:path, subject to the watermark values. Watermarks are based on overall % volume used, even if the SF volume is specified as volume:path 

$PROG <volume> [options] 

   -h, --help              - print this help and exit

Required:
   <volume>	              - Starfish volume to remove data from. Accepts <volume:path> format
   --email <recipients>	      - Email notifications to <recipients> (comma separated)

Optional:
   --days		      - Remove data older than X days (Default 365)
   --from <sender>	      - Email sender (default: root)
   --atime                    - Use only atime (default is latest of a/m/ctime)
   --mtime		      - Use only mtime (default is latest of a/m/ctime)
   --ctime                    - Use only ctime (default is latest of a/m/ctime)
   --dry-run		      - Do not actually remove data. Useful to see what files would be rmeoved.
   --low <#>		      - Specify a low water mark for % volume used (between 0 and 100)
   --high <#>		      - Specify a high water mark for % volume used (between 0 and 100)
   --exclude <filename>	      - Specify an exclusion list (Uses simple pattern matching, and this file should have no empty lines)
   --exclgroup <groupname>    - Exclude files belonging to <groupname>

Examples:
$PROG nfs1:/data/project1 --dry-run --days 90 --from sysadmin@company.com  --email a@company.com,b@company.com
Run $PROG for SF volume nfs1:/data/project1, in dry run mode, looking to remove files older than 90 days.  Email results to users a@company.com and b@company.com, coming from sysadmin@company.com

$PROG nfs1: --days 90 --low 80 --high 85 --email a@company.com --mtime 
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
    "--ctime")
      MODIFIER="c"
      ;;
    "--atime")
      MODIFIER="a"
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
    "--exclgroup")
      check_parameters_value "$@"
      shift
      EXCLGROUP=$1
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
  if [[ -n $EXCLGROUP ]]; then
    logprint " Exclude group: $EXCLGROUP"
  fi
  logprint " Volume: $SFVOLUME"
  logprint " Days: $DAYS_AGO"
  logprint " a/m/ctime: $MODIFIER"
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
  totaltally=`awk -v outfile="$2" -v amounttodelete="$TOREMOVE" -F, '
    BEGIN { rollingtally=0 }
    {
      if (rollingtally < amounttodelete) 
        {
          rollingtally=rollingtally+$2; print $1 > outfile
        }
      else { exit(0); }
    }
    END { print rollingtally }' $1`
  logprint "Total data being sent to job engine for deletion: $totaltally Bytes"
}

run_sf_query() {
# Run the SF query command, outputting values for atime, mtime, ctime, volume, path, filename, and size to -raw.tmp file
  local errorcode
  local joboutput
  local timeframe
  local older_than
  local excludegroup
  
  if [[ -n $EXCLGROUP ]]; then
    excludegroup="--not --groupname $EXCLGROUP"
  else
   excludegroup=""
  fi
  older_than="$(date --date "${DAYS_AGO} days ago" +"%Y%m%d")"
  case $MODIFIER in
    "m")
      timeframe="--mtime 19000101-$older_than"
      ;;
    "a")
      timeframe="--atime 19000101-$older_than"
      ;;
    "c")
      timeframe="--ctime 19000101-$older_than"
      ;;
    "amc")
      timeframe="--atime 19000101-$older_than --mtime 19000101-$older_than --ctime 19000101-$older_than"
      ;;
    "*")
      echo "Value for a/m/ctime unknown. Exiting.."
      ;;
  esac
  set +e
  joboutput="$(${SF} query $SFVOLUME --size 0-0 $timeframe --type f -H -d, --format "at mt ct volume path fn size" $excludegroup > ${FILELIST}-raw.tmp)"
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
  if [[ ! -s ${FILELIST}-raw.tmp ]]; then
    logprint "SF query returned empty result. Exiting.."
    echo "SF query returned empty result. Exiting.."
    email_alert "SF query returnd empty result. Exiting.."
    exit 1
  fi
}

format_results() {
# passing in $AGEONLY
# Sort the -raw.tmp file based atime, mtime, ctime, or the latest of all three. 
  logprint "Formatting results:"
  logprint " Sorting results"
  case $MODIFIER in
    "a")
      sort -k1 -n ${FILELIST}-raw.tmp > ${FILELIST}-1-sorted.tmp
      ;;
    "m")
      sort -k2 -n ${FILELIST}-raw.tmp > ${FILELIST}-1-sorted.tmp
      ;;
    "c")
      sort -k3 -n ${FILELIST}-raw.tmp > ${FILELIST}-1-sorted.tmp
      ;;
    "amc")
      awk -F, '\
      {
        largest=$1
        if (largest < $2)
          largest=$2;
        if (largest < $3)
          largest=$3;
        print largest","$4","$5","$6","$7
      }' < ${FILELIST}-raw.tmp > ${FILELIST}-1a-sorted.tmp
      sort ${FILELIST}-1a-sorted.tmp > ${FILELIST}-1-sorted.tmp
      ;;
  esac
#  rm ${FILELIST}-raw.tmp
# Remove timestamps from file because we no longer need them, as the data is already sorted. 
  logprint " Removing time values from file"
  sed 's/^[^,]*,//g' < ${FILELIST}-1-sorted.tmp > ${FILELIST}-2-notime.tmp
# format json output converts from json output ("vol","path","fn") to something we can almost use (/volume/path/fn,size). Final comma in output is kept to make it easier to remove the size value later on.
  logprint " Formatting JSON output:"
  format_json_output ${FILELIST}-2-notime.tmp ${FILELIST}-3-formatted.tmp
# remove exclusions
  if [[ -n $EXCLUDELIST ]]; then
    remove_exclusions $EXCLUDELIST ${FILELIST}-3-formatted.tmp
  fi
# Determine whether further processing is based on age, or age + watermarks
  if [[ $1 = "0" ]]; then
    logprint "Processing query based on age and watermarks"
  elif [[ $1 = "1" ]]; then
    logprint "Processing query based on age only:"
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
  if [[ $PCENTUSED -ge $HIGHMARK ]]; then
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
build_and_run_job_command ${FILELIST}-5-final.tmp
echo "Step 5 Complete"
email_notify "Options specified: $SFVOLUME, use ${MODIFIER}time, files older than $DAYS_AGO days old, $DRYRUN
A list of files sent to the SF job engine for deletion can be found at ${FILELIST}-5-final.tmp (${FILELIST}-4-tallied.tmp for a more human readable version)"
echo "Script complete"
echo "NOTE: A new SF scan should be run prior to running this script again!"

