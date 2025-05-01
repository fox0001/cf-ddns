#!/bin/bash
##############################################################################
# Cloudflare DDNS
# - Binding current WAN IP to Cloudflare DNS
# - Compatible with Bash and BusyBox
#
# refer
# - Cloudflare API document: https://developers.cloudflare.com/api
##############################################################################

# Configure
DOMAIN=
CF_KEY=
CF_ZONE_ID=
CF_RECORD_ID=
IS_DEBUG=0

# Init value
FILE_NAME=$0
CF_API="https://api.cloudflare.com/client/v4/zones"
CF_RECORD_TYPE=A
OLD_IP=
URL_WAN_IP="https://icanhazip.com"
WAN_IP=

# function: log
log() {
  if [ -z "$*" ]; then
    return
  fi
  case "$1" in
    "i")
      logLv=I
      ;;
    "w")
      logLv=W
      ;;
    "e")
      logLv=E
      ;;
  esac
  msg=$2
  # Get current time, accurate to milliseconds
  curTime=$(date +"%Y%m%d_%H%M%S.%3N")
  echo ${FILE_NAME}, $curTime [$logLv] $msg 1>&2
  return
}

# function: Show help info
show_help() {
  cat 1>&2 <<EOF
Usage: ${FILE_NAME} [options...]
  -p <parms> Params, format: DOMAIN=xxx,CF_KEY=xxx,CF_ZONE_ID=xxx,CF_RECORD_ID=xxx
  -d         Enable debug mode
  -h         Show this help info
EOF
}

# function: Get parameters
get_params() {
  if [ -z "$*" ]; then
    log e "No options! Using "-h" for help."
    return 1
  fi
  while getopts "p:dh" optname; do
    case "$optname" in
      "p")
        DOMAIN=$(echo $OPTARG | sed -E 's/^.+?,?DOMAIN=([^,]+),?.+?$/\1/')
        CF_KEY=$(echo $OPTARG | sed -E 's/^.+?,?CF_KEY=([^,]+),?.+?$/\1/')
        CF_ZONE_ID=$(echo $OPTARG | sed -E 's/^.+?,?CF_ZONE_ID=([^,]+),?.+?$/\1/')
        CF_RECORD_ID=$(echo $OPTARG | sed -E 's/^.+?,?CF_RECORD_ID=([^,]+),?.+?$/\1/')
        ;;
      "d")
        IS_DEBUG=1
        ;;
      "h")
        show_help
        return 1
        ;;
      *)
        log e "Unknown option: $optname. Using "-h" for help."
        return 1
        ;;
    esac
  done

  # Check the required parameters
  is_pass=1
  if [ -z "${DOMAIN}" ]; then
    log e "Domain is empty."
    is_pass=0
  fi
  if [ -z "${CF_KEY}" ]; then
    log e "Cloudflare key is empty."
    is_pass=0
  fi
  if [ -z "${CF_ZONE_ID}" ]; then
    log e "Cloudflare zone id is empty."
    is_pass=0
  fi
  if [ -z "${CF_RECORD_ID}" ]; then
    log e "Cloudflare DNS record id is empty."
    is_pass=0
  fi
  if [ "$is_pass" == "0" ]; then
    return 1
  fi
  return 0
}

# function: Get current IP of WAN
get_wan_ip() {
  # Get WAN IP from remote url
  curl -X GET "${URL_WAN_IP}" --connect-timeout 10 -m 10 2>/dev/null
  # Get WAN IP from the interface of router
  #(sleep 1; echo "ip addr show dev pppoe-wan"; sleep 1; ) | telnet 192.168.23.1 2>/dev/null | grep -oP '(?<=inet\ )[0-9\.]+' 
  # Get WAN IP on router 
  #echo $(ip addr show dev pppoe-wan | grep -oE 'inet[[:blank:]]+[0-9\.]+' | sed -E 's/^.+?inet[[:blank:]]+([0-9\.]+).+?$/\1/')
}

# function: Request Cloudflare API
cf_req() {
  # $1: API path
  # $2: request method
  # $3: send data of POST or PUT
  # $4: seconds of transfer timeout, default 30
  max_timeout=30
  if [ -n "$4" ]; then
    max_timeout=$4
  fi
  curl -k -X $2 "${CF_API}$1" -H "Authorization: Bearer ${CF_KEY}" -H "Content-Type: application/json" --connect-timeout 10 -m ${max_timeout} -d "$3" 2>/dev/null
}

# function: Get old IP
get_old_ip() {
  json=$(cf_req "/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" GET)
  if [ -z "$json" ]; then
    echo ""
    return 1
  fi
  if [ "$(echo $json | sed -E 's/^.+?"success"\:(true).+?$/\1/')" != "true" ]; then
    echo ""
    return 1
  fi
  echo $(echo $json | sed -E 's/^.+?"content"\:"([0-9\.]+)".+?$/\1/')
  return 0
}

# function: Get record type, A(IPv4) | AAAA(IPv6), default IPv4 
get_record_type() {
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

# function: Update new IP to Cloudflare DNS
update_record() {
  #put_data="{\"type\":\"${CF_RECORD_TYPE}\",\"name\":\"${DOMAIN}\",\"content\":\"${WAN_IP}\",\"ttl\":1}"
  #json=$(cf_req "/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" PUT "$put_data")
  patch_data="{\"type\":\"${CF_RECORD_TYPE}\",\"content\":\"${WAN_IP}\"}"
  json=$(cf_req "/${CF_ZONE_ID}/dns_records/${CF_RECORD_ID}" PATCH "$patch_data")
  #log i "update_record result: $json"
  if [ -z "$json" ]; then
    return 1
  fi
  if [ "$(echo $json | sed -E 's/^.+?"success"\:(true).+?$/\1/')" != "true" ]; then
    return 1
  fi
  return 0
}

# function: Main
main() {
  get_params $*
  if [ "$?" != "0" ]; then
    exit 1
  fi

  OLD_IP=$(get_old_ip)
  #log i "get_record_json: ${CF_RECORD_JSON}"
  if [ -z "${OLD_IP}" ]; then
    log e "Get old IP failed."
    exit 1
  fi

  WAN_IP=$(get_wan_ip)
  #log i "new ip: ${WAN_IP}, old ip: ${OLD_IP}"
  if [ -z "${WAN_IP}" ]; then
    log e "Get Wan IP failed."
    exit 1
  fi
  if [ "${OLD_IP}" == "${WAN_IP}" ]; then
    log i "IP has not changed"
    exit 0
  fi

  CF_RECORD_TYPE=$(get_record_type ${WAN_IP})
  #log i "record type: ${CF_RECORD_TYPE}"

  update_record
  if [ "$?" != "0" ]; then
    log e "Update DDNS failed. New IP: ${WAN_IP}, old IP: ${OLD_IP}"
    exit 1
  fi
  log i "Update DDNS succeed. New IP: ${WAN_IP}"
  exit 0
}

main $*

