#!/bin/bash
##############################################################################
# Cloudflare DDNS
# - Binding current WAN IP to Cloudflare DNS
#
# refer
# - Cloudflare API document: https://developers.cloudflare.com/api
##############################################################################

# Configure
DOMAIN=
CF_KEY=
IS_DEBUG=0

# Init value
URL_WAN_IP="https://icanhazip.com"
#CF_INFO="cf_info.json"
CF_API="https://api.cloudflare.com/client/v4/zones"
CF_ZONE_ID=
CF_RECORD_JSON=
CF_RECORD_ID=
CF_RECORD_TYPE=A
WAN_IP=
FILE_NAME=$0

# Log
declare -A LOG_LEVEL=([i]=I [w]=W [e]=E)
function log() {
    if [ -z "$*" ]; then
        return
    fi
	# Get current time, accurate to milliseconds
	curTime=$(date +"%Y%m%d_%H%M%S.%3N")
	logLv=${LOG_LEVEL[$1]}
	msg=$2
	echo $curTime [$logLv] $msg 1>&2
    if [ "$1" == "e" ]; then
      exit 1
    fi
	return
}

function show_help() {
  cat 1>&2 <<EOF
Usage: ${FILE_NAME} [options...]
  -n <domain>  Domain to set IP
  -k <key>     Cloudflare key
  -d           Enable debug mode
  -h           Show this help info
EOF
}

function get_params() {
  if [ -z "$*" ]; then
    log e "No options! Using "-h" for help."
    return
  fi
  while getopts ":n:k:dh" optname; do
    case "$optname" in
      "n")
        DOMAIN=$OPTARG
        ;;
      "k")
        CF_KEY=$OPTARG
        ;;
      "d")
        IS_DEBUG=1
        ;;
      "h")
        show_help
        exit 1
        ;;
      *)
        log e "Unknown option: $optname. Using "-h" for help."
        ;;
    esac
  done
  if [ -z "${DOMAIN}" ]; then
    log e "Domain is empty."
  fi
  if [ -z "${CF_KEY}" ]; then
    log e "Cloudflare key is empty."
  fi
}

# Get current IP of WAN
function get_wan_ip() {
  curl -X GET "${URL_WAN_IP}" --connect-timeout 10 -m 10 2>/dev/null
}

# request Cloudflare API
function cf_req() {
  # $1: API path
  # $2: request method
  # $3: send data of POST or PUT
  # $4: seconds of transfer timeout, default 30
  max_timeout=30
  if [ -n "$4" ]; then
    max_timeout=$4
  fi
  curl -X $2 "${CF_API}$1" -H "Authorization: Bearer ${CF_KEY}" -H "Content-Type: application/json" --connect-timeout 10 -m ${max_timeout} -d "$3" 2>/dev/null
}

function get_zone_id() {
  # no params
  json=$(cf_req "" GET)
  if [ -z "$json" ]; then
    return 1
  fi
  if [ "$(echo $json | jq '.success')" != "true" ]; then
    return 1
  fi
  echo $(echo $json | jq -r --arg DOMAIN "${DOMAIN}" '.result[] | select(.name | inside($DOMAIN)) | .id')
  return 0
}

function get_record_json() {
  # $1: zone_id
  json=$(cf_req "/$1/dns_records" GET)
  if [ -z "$json" ]; then
    return 1
  fi
  if [ "$(echo $json | jq '.success')" != "true" ]; then
    return 1
  fi
  echo $(echo $json | jq -r --arg DOMAIN "${DOMAIN}" '.result[] | select(.name == $DOMAIN) | .')
  return 0
}

# Get record type, A(IPv4) | AAAA(IPv6), default IPv4 
function get_record_type() {
  # $1: ip address
  if [ "$1" != "${1#*[0-9].[0-9]}" ]; then
    echo A
  elif [ "$1" != "${1#*:[0-9a-fA-F]}" ]; then
    echo AAAA
  else
    # Unknown
    echo ""
  fi
}

function update_record() {
  put_data="{\"id\":\"${CF_ZONE_ID}\",\"type\":\"${CF_RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${WAN_IP}\", \"ttl\":1}"
  json=$(cf_req "/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" PUT "$put_data")
  #log i "update_record result: $json"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ "$(echo $json | jq '.success')" != "true" ]; then
    return 1
  fi
  return 0
}

function main() {
  get_params $*

  CF_ZONE_ID=$(get_zone_id)
  #log i "get_zone_id: ${CF_ZONE_ID}"
  if [ -z "${CF_ZONE_ID}" ]; then
    log e "Get Cloudflare zone id failed."
  fi

  CF_RECORD_JSON=$(get_record_json ${CF_ZONE_ID})
  #log i "get_record_json: ${CF_RECORD_JSON}"
  if [ -z "${CF_RECORD_JSON}" ]; then
    log e "Get Cloudflare DNS record failed."
  fi

  OLD_IP=$(echo ${CF_RECORD_JSON} | jq -r '.content')
  WAN_IP=$(get_wan_ip)
  #log i "new ip: ${WAN_IP}, old ip: ${OLD_IP}"
  if [ -z "${WAN_IP}" ]; then
    log e "Get Wan IP failed."
  fi
  if [ "${OLD_IP}" == "${WAN_IP}" ]; then
    log i "IP has not changed"
    return 0
  fi

  CF_RECORD_ID=$(echo ${CF_RECORD_JSON} | jq -r '.id')
  #log i "record id: ${CF_RECORD_ID}"
  if [ -z "${CF_RECORD_ID}" ]; then
    log e "Get Cloudflare DNS record id failed."
  fi

  CF_RECORD_TYPE=$(get_record_type ${WAN_IP})
  #log i "record type: ${CF_RECORD_TYPE}"
  if [ -z "${WAN_IP}" ]; then
    log e "Get IP type failed."
  fi

  update_record
  if [ "$?" == "0" ]; then
    log i "Update DDNS succeed. New IP: ${WAN_IP}"
  else
    log e "Update DDNS failed. New IP: ${WAN_IP}, old IP: ${}"
  fi
}
main $*

