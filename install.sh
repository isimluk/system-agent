#!/bin/sh

if [ "${DEBUG}" = 1 ]; then
    set -x
    CURL_LOG="-v"
else
    CURL_LOG="-sS"
fi

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./install.sh
#

# Environment variables:
#   System Agent Variables
#   - CATTLE_AGENT_LOGLEVEL (default: info)
#   - CATTLE_AGENT_CONFIG_DIR (default: /etc/rancher/agent)
#   - CATTLE_AGENT_VAR_DIR (default: /var/lib/rancher/agent)
#   - CATTLE_AGENT_BIN_PREFIX (default: /usr/local)
#
#   Rancher 2.6+ Variables
#   - CATTLE_SERVER
#   - CATTLE_TOKEN
#   - CATTLE_CA_CHECKSUM
#   - CATTLE_ROLE_CONTROLPLANE=false
#   - CATTLE_ROLE_ETCD=false
#   - CATTLE_ROLE_WORKER=false
#   - CATTLE_ROLE_NONE=false
#   - CATTLE_LABELS
#   - CATTLE_TAINTS
#
#   Advanced Environment Variables
#   - CATTLE_AGENT_BINARY_BASE_URL (default: latest GitHub release)
#   - CATTLE_AGENT_BINARY_URL (default: latest GitHub release)
#   - CATTLE_AGENT_UNINSTALL_URL (default: latest GitHub release)
#   - CATTLE_PRESERVE_WORKDIR (default: false)
#   - CATTLE_REMOTE_ENABLED (default: true)
#   - CATTLE_LOCAL_ENABLED (default: false)
#   - CATTLE_ID (default: autogenerate)
#   - CATTLE_AGENT_BINARY_LOCAL (default: false)
#   - CATTLE_AGENT_BINARY_LOCAL_LOCATION (default: )
#   - CATTLE_AGENT_UNINSTALL_LOCAL (default: false)
#   - CATTLE_AGENT_UNINSTALL_LOCAL_LOCATION (default: )

FALLBACK=v0.2.9
CACERTS_PATH=cacerts
RETRYCOUNT=4500

# info logs the given argument at info log level.
info() {
    echo "[INFO] " "$@"
}

# warn logs the given argument at warn log level.
warn() {
    echo "[WARN] " "$@" >&2
}

# error logs the given argument at error log level.
error() {
    echo "[ERROR] " "$@" >&2
}

# fatal logs the given argument at fatal log level.
fatal() {
    echo "[FATAL] " "$@" >&2
    exit 1
}

# check_target_mountpoint return success if the target directory is on a dedicated mount point
check_target_mountpoint() {
    mountpoint -q "${CATTLE_AGENT_BIN_PREFIX}"
}

# check_target_ro returns success if the target directory is read-only
check_target_ro() {
    touch "${CATTLE_AGENT_BIN_PREFIX}"/.r-sa-ro-test && rm -rf "${CATTLE_AGENT_BIN_PREFIX}"/.r-sa-ro-test
    test $? -ne 0
}

# check_rootfs_rw returns success if the root filesystem is read-write so we can check for transactional-update system
check_rootfs_rw() {
    touch /.rootfs-rw-test && rm -rf /.rootfs-rw-test
    test $? -eq 0
}

# parse_args will inspect the argv for --server, --token, --controlplane, --etcd, and --worker, --label x=y, and --taint dead=beef:NoSchedule
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        "-a" | "--all-roles")
            info "All roles requested"
            CATTLE_ROLE_CONTROLPLANE=true
            CATTLE_ROLE_ETCD=true
            CATTLE_ROLE_WORKER=true
            shift 1
            ;;
        "-p" | "--controlplane")
            info "Role requested: controlplane"
            CATTLE_ROLE_CONTROLPLANE=true
            shift 1
            ;;
        "-e" | "--etcd")
            info "Role requested: etcd"
            CATTLE_ROLE_ETCD=true
            shift 1
                ;;
        "-w" | "--worker")
            info "Role requested: worker"
            CATTLE_ROLE_WORKER=true
		        shift 1
            ;;
        "--no-roles")
            info "Role requested: none"
            CATTLE_ROLE_NONE=true
            shift 1
            ;;
        "-n" | "--node-name")
            CATTLE_NODE_NAME="$2"
		        shift 2
            ;;
        "-a" | "--address")
            CATTLE_ADDRESS="$2"
		        shift 2
            ;;
        "-i" | "--internal-address")
            CATTLE_INTERNAL_ADDRESS="$2"
		        shift 2
            ;;
        "-l" | "--label")
            info "Label: $2"
            if [ -n "${CATTLE_LABELS}" ]; then
                CATTLE_LABELS="${CATTLE_LABELS},$2"
            else
                CATTLE_LABELS="$2"
            fi
		        shift 2
            ;;
        "--taint" | "--taints")
            info "Taint: $2"
            if [ -n "${CATTLE_TAINTS}" ]; then
                CATTLE_TAINTS="${CATTLE_TAINTS},$2"
            else
                CATTLE_TAINTS="$2"
            fi
		        shift 2
            ;;
        "-s" | "--server")
            CATTLE_SERVER="$2"
		        shift 2
            ;;
        "-t" | "--token")
            CATTLE_TOKEN="$2"
		        shift 2
            ;;
        "-c" | "--ca-checksum")
            CATTLE_CA_CHECKSUM="$2"
            shift 2
            ;;
        *)
            fatal "Unknown argument passed in ($1)"
            ;;
        esac
    done
}

in_no_proxy() {
    # Get just the host name/IP
    ip_addr="${1#http://}"
    ip_addr="${ip_addr#https://}"
    ip_addr="${ip_addr%%/*}"
    ip_addr="${ip_addr%%:*}"

    # If this isn't an IP address, then there is nothing to check
    if [ "$(valid_ip "$ip_addr")" = "1" ]; then
      echo 1
      return
    fi

    i=1
    proxy_ip=$(echo "$NO_PROXY" | cut -d',' -f$i)
    while [ -n "$proxy_ip" ]; do
      subnet_ip=$(echo "${proxy_ip}" | cut -d'/' -f1)
      cidr_mask=$(echo "${proxy_ip}" | cut -d'/' -f2)

      if [ "$(valid_ip "$subnet_ip")" = "0" ]; then
        # If these were the same, then proxy_ip is an IP address, not a CIDR. curl handles this correctly.
        if [ "$cidr_mask" != "$subnet_ip" ]; then
          cidr_mask=$(( 32 - cidr_mask ))
          shift_multiply=1
          while [ "$cidr_mask" -gt 0 ]; do
            shift_multiply=$(( shift_multiply * 2 ))
            cidr_mask=$(( cidr_mask - 1 ))
          done

          # Manual left-shift (<<) by original cidr_mask value
          netmask=$(( 0xFFFFFFFF * shift_multiply ))

          # Apply netmask to both the subnet IP and the given IP address
          ip_addr_subnet=$(and "$(ip_to_int "$subnet_ip")" $netmask)
          subnet=$(and "$(ip_to_int "$ip_addr")" $netmask)

          # Subnet IPs will match if given IP address is in CIDR subnet
          if [ "${ip_addr_subnet}" -eq "${subnet}" ]; then
            echo 0
            return
          fi
        fi
      fi

      i=$(( i + 1 ))
      proxy_ip=$(echo "$NO_PROXY" | cut -d',' -s -f$i)
    done

    echo 1
}

# bitwise 'and' in /bin/sh is not supported, so we do it manually.
and() {
    ret=0
    first=${1}
    second=${2}
    if [ "$first" -gt "$second" ]; then
        tmp=$first
        first=$second
        second=$tmp
    fi

    while [ "$first" -gt 0 ]; do
        ret=$(( ret * 2 ))
        d1=$(( first % 2 ))
        d2=$(( second % 2 ))
        ans=$(( d1 * d2 ))
        if [ "$ans" -eq 1 ]; then
            ret=$(( ret + 1 ))
        fi
        second=$(( second / 2 ))
        first=$(( first / 2 ))
    done

    echo $ret
}

ip_to_int() {
    ip_addr="${1}"

    ip_1=$(echo "${ip_addr}" | cut -d'.' -f1)
    ip_2=$(echo "${ip_addr}" | cut -d'.' -f2)
    ip_3=$(echo "${ip_addr}" | cut -d'.' -f3)
    ip_4=$(echo "${ip_addr}" | cut -d'.' -f4)

    echo $(( $ip_1 * 256*256*256 + $ip_2 * 256*256 + $ip_3 * 256 + $ip_4 ))
}

valid_ip() {
    local IP="$1" IFS="." PART
    set -- $IP
    [ "$#" != 4 ] && echo 1 && return
    for PART; do
        case "$PART" in
            *[!0-9]*) echo 1 && return
        esac
        [ "$PART" -gt 255 ] && echo 1 && return
    done
    echo 0
}

setup_env() {
    if [ -z "${CATTLE_ROLE_CONTROLPLANE}" ]; then
        CATTLE_ROLE_CONTROLPLANE=false
    fi

    if [ -z "${CATTLE_ROLE_ETCD}" ]; then
        CATTLE_ROLE_ETCD=false
    fi

    if [ -z "${CATTLE_ROLE_WORKER}" ]; then
        CATTLE_ROLE_WORKER=false
    fi

    if [ -z "${CATTLE_ROLE_NONE}" ]; then
        CATTLE_ROLE_NONE=false
    fi

    if [ "${CATTLE_ROLE_NONE}" = "true" ]; then
        info "--no-roles flag passed, unsetting all other requested roles"
        CATTLE_ROLE_CONTROLPLANE=false
        CATTLE_ROLE_ETCD=false
        CATTLE_ROLE_WORKER=false
    fi

    if [ -z "${CATTLE_LOCAL_ENABLED}" ]; then
        CATTLE_LOCAL_ENABLED=false
    else
        CATTLE_LOCAL_ENABLED=$(echo "${CATTLE_LOCAL_ENABLED}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ -z "${CATTLE_REMOTE_ENABLED}" ]; then
        CATTLE_REMOTE_ENABLED=true
    else
        CATTLE_REMOTE_ENABLED=$(echo "${CATTLE_REMOTE_ENABLED}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "${CATTLE_LOCAL_ENABLED}" = "false" ] && [ "${CATTLE_REMOTE_ENABLED}" = "false" ]; then
        fatal "Neither local or remote plan support was enabled"
    fi

    if [ -z "${CATTLE_PRESERVE_WORKDIR}" ]; then
        CATTLE_PRESERVE_WORKDIR=false
    else
        CATTLE_PRESERVE_WORKDIR=$(echo "${CATTLE_PRESERVE_WORKDIR}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ -z "${CATTLE_AGENT_LOGLEVEL}" ]; then
        CATTLE_AGENT_LOGLEVEL=info
    else
        CATTLE_AGENT_LOGLEVEL=$(echo "${CATTLE_AGENT_LOGLEVEL}" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "${CATTLE_AGENT_BINARY_LOCAL}" = "true" ]; then
        if [ -z "${CATTLE_AGENT_BINARY_LOCAL_LOCATION}" ]; then
            fatal "No local binary location was specified"
        fi
        BINARY_SOURCE=local
    else
        BINARY_SOURCE=remote

        if [ -z "${CATTLE_AGENT_BINARY_URL}" ] && [ -n "${CATTLE_AGENT_BINARY_BASE_URL}" ]; then
            CATTLE_AGENT_BINARY_URL="${CATTLE_AGENT_BINARY_BASE_URL}/rancher-system-agent-${ARCH}"
        fi

        if [ -z "${CATTLE_AGENT_BINARY_URL}" ]; then
            if [ $(curl --connect-timeout 60 --max-time 60 -s https://api.github.com/rate_limit | grep '"rate":' -A 4 | grep '"remaining":' | sed -E 's/.*"[^"]+": (.*),/\1/') = 0 ]; then
                info "GitHub Rate Limit exceeded, falling back to known good version"
                VERSION=$FALLBACK
            else
                VERSION=$(curl --connect-timeout 60 --max-time 60 -s "https://api.github.com/repos/rancher/system-agent/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                if [ -z "$VERSION" ]; then # Fall back to a known good fallback version because we had an error pulling the latest
                    info "Error contacting GitHub to retrieve the latest version"
                    VERSION=$FALLBACK
                fi
            fi
            CATTLE_AGENT_BINARY_URL="https://github.com/rancher/system-agent/releases/download/${VERSION}/rancher-system-agent-${ARCH}"
            BINARY_SOURCE=upstream
        fi
    fi

    if [ "${CATTLE_AGENT_UNINSTALL_LOCAL}" = "true" ]; then
        if [ -z "${CATTLE_AGENT_UNINSTALL_LOCAL_LOCATION}" ]; then
            fatal "No local uninstall location was specified"
        fi
        UNINSTALL_SOURCE=local
    else
        UNINSTALL_SOURCE=remote

        if [ -z "${CATTLE_AGENT_UNINSTALL_URL}" ] && [ -n "${CATTLE_AGENT_BINARY_BASE_URL}" ]; then
            CATTLE_AGENT_UNINSTALL_URL="${CATTLE_AGENT_BINARY_BASE_URL}/system-agent-uninstall.sh"
        fi

        if [ -z "${CATTLE_AGENT_UNINSTALL_URL}" ]; then
            if [ -n "${VERSION}" ]; then
                info "Version ${VERSION} used for downloading the rancher-system-agent binary, will reuse for uninstall script"
            elif [ $(curl --connect-timeout 60 --max-time 60 -s https://api.github.com/rate_limit | grep '"rate":' -A 4 | grep '"remaining":' | sed -E 's/.*"[^"]+": (.*),/\1/') = 0 ]; then
                info "GitHub Rate Limit exceeded, falling back to known good version"
                VERSION=$FALLBACK
            else
                VERSION=$(curl --connect-timeout 60 --max-time 60 -s "https://api.github.com/repos/rancher/system-agent/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
                if [ -z "$VERSION" ]; then # Fall back to a known good fallback version because we had an error pulling the latest
                    info "Error contacting GitHub to retrieve the latest version"
                    VERSION=$FALLBACK
                fi
            fi
            CATTLE_AGENT_UNINSTALL_URL="https://github.com/rancher/system-agent/releases/download/${VERSION}/system-agent-uninstall.sh"
            UNINSTALL_SOURCE=upstream
        fi
    fi

    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        if [ -z "${CATTLE_TOKEN}" ]; then
            fatal "\$CATTLE_TOKEN was not set."
        fi
        if [ -z "${CATTLE_SERVER}" ]; then
            fatal "\$CATTLE_SERVER was not set"
        fi
        if [ "${CATTLE_ROLE_CONTROLPLANE}" = "false" ] && [ "${CATTLE_ROLE_ETCD}" = "false" ] && [ "${CATTLE_ROLE_WORKER}" = "false" ] && [ "${CATTLE_ROLE_NONE}" = "false" ]; then
            fatal "You must select at least one role."
        fi
    fi

    if [ -z "${CATTLE_AGENT_CONFIG_DIR}" ]; then
        CATTLE_AGENT_CONFIG_DIR=/etc/rancher/agent
        info "Using default agent configuration directory ${CATTLE_AGENT_CONFIG_DIR}"
    fi

    # --- install to /var/lib/rancher/agent by default, except if we are running within transactional-update
    # --- in which case we install into /etc/rancher/agent/var as /var is not mounted to the snapshot.
    if [ -z "${CATTLE_AGENT_VAR_DIR}" ]; then
        if [ -x /usr/sbin/transactional-update ] && check_rootfs_rw; then
            CATTLE_AGENT_VAR_DIR=/etc/rancher/agent/var
            info "Detected a transactional-update server, using ${CATTLE_AGENT_VAR_DIR} for agent var directory"
        else
            CATTLE_AGENT_VAR_DIR=/var/lib/rancher/agent
            info "Using default agent var directory ${CATTLE_AGENT_VAR_DIR}"
        fi
    fi

    # --- install to /usr/local by default, except if /usr/local is on a separate partition or is read-only
    # --- in which case we go into /opt/rancher-system-agent. If we are running within transactional-update
    # --- we install to /usr as /usr/local and /opt are not mounted to the snapshot.
    if [ -z "${CATTLE_AGENT_BIN_PREFIX}" ]; then
        CATTLE_AGENT_BIN_PREFIX="/usr/local"
        if check_target_mountpoint || check_target_ro; then
            CATTLE_AGENT_BIN_PREFIX="/opt/rancher-system-agent"
            warn "/usr/local is read-only or a mount point; installing to ${CATTLE_AGENT_BIN_PREFIX}"
        fi
        if [ -x /usr/sbin/transactional-update ] && check_rootfs_rw; then
            CATTLE_AGENT_BIN_PREFIX=/usr
            warn "Detected transactional-update in progress; installing to ${CATTLE_AGENT_BIN_PREFIX}"
        fi
    fi

    CATTLE_ADDRESS=$(get_address "${CATTLE_ADDRESS}")
    CATTLE_INTERNAL_ADDRESS=$(get_address "${CATTLE_INTERNAL_ADDRESS}")
}

ensure_directories() {
    mkdir -p ${CATTLE_AGENT_VAR_DIR}
    mkdir -p ${CATTLE_AGENT_CONFIG_DIR}
    chmod 700 ${CATTLE_AGENT_VAR_DIR}
    chmod 700 ${CATTLE_AGENT_CONFIG_DIR}
    chown root:root ${CATTLE_AGENT_VAR_DIR}
    chown root:root ${CATTLE_AGENT_CONFIG_DIR}
}

# setup_arch set arch and suffix,
# fatal if architecture not supported.
setup_arch() {
    case ${ARCH:=$(uname -m)} in
    amd64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    x86_64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    arm64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    s390x)
        ARCH=s390x
        SUFFIX=-${ARCH}
        ;;
    aarch64)
        ARCH=arm64
        SUFFIX=-${ARCH}
        ;;
    arm*)
        ARCH=arm
        SUFFIX=-${ARCH}hf
        ;;
    *)
        fatal "unsupported architecture ${ARCH}"
        ;;
    esac
}

get_address()
{
    local address=$1
    # If nothing is given, return empty (it will be automatically determined later if empty)
    if [ -z $address ]; then
        echo ""
    # If given address is a network interface on the system, retrieve configured IP on that interface (only the first configured IP is taken)
    elif [ -n "$(find /sys/devices -name $address)" ]; then
        echo $(ip addr show dev $address | grep -w inet | awk '{print $2}' | cut -f1 -d/ | head -1)
    # Loop through cloud provider options to get IP from metadata, if not found return given value
    else
        noproxy=""
        if [ "$(in_no_proxy "169.254.169.254")" -eq 0 ]; then
          noproxy="--noproxy '*'"
        fi
        case $address in
            awslocal)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s http://169.254.169.254/latest/meta-data/local-ipv4)
                ;;
            awspublic)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s http://169.254.169.254/latest/meta-data/public-ipv4)
                ;;
            doprivate)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
                ;;
            dopublic)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
                ;;
            azprivate)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2017-08-01&format=text")
                ;;
            azpublic)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s -H Metadata:true "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2017-08-01&format=text")
                ;;
            gceinternal)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
                ;;
            gceexternal)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
                ;;
            packetlocal)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s https://metadata.packet.net/2009-04-04/meta-data/local-ipv4)
                ;;
            packetpublic)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s https://metadata.packet.net/2009-04-04/meta-data/public-ipv4)
                ;;
            ipify)
                echo $(curl $noproxy --connect-timeout 60 --max-time 60 -s https://api.ipify.org)
                ;;
            *)
                echo $address
                ;;
        esac
    fi
}

# verify_downloader verifies existence of
# network downloader executable.
verify_downloader() {
    cmd="$(command -v "${1}")"
    if [ -z "${cmd}" ]; then
        return 1
    fi
    if [ ! -x "${cmd}" ]; then
        return 1
    fi

    # Set verified executable as our downloader program and return success
    DOWNLOADER=${cmd}
    return 0
}

# --- write systemd service file ---
create_systemd_service_file() {
    info "systemd: Creating service file"
    cat <<-EOF >"/etc/systemd/system/rancher-system-agent.service"
[Unit]
Description=Rancher System Agent
Documentation=https://www.rancher.com
Wants=network-online.target
After=network-online.target
[Install]
WantedBy=multi-user.target
[Service]
EnvironmentFile=-/etc/default/rancher-system-agent
EnvironmentFile=-/etc/sysconfig/rancher-system-agent
EnvironmentFile=-/etc/systemd/system/rancher-system-agent.env
Type=simple
Restart=always
RestartSec=5s
Environment=CATTLE_LOGLEVEL=${CATTLE_AGENT_LOGLEVEL}
Environment=CATTLE_AGENT_CONFIG=${CATTLE_AGENT_CONFIG_DIR}/config.yaml
ExecStart=${CATTLE_AGENT_BIN_PREFIX}/bin/rancher-system-agent sentinel
EOF
}

download_rancher_files() {
  mkdir -p ${CATTLE_AGENT_BIN_PREFIX}/bin

  download_rancher_file "rancher-system-agent" "binary" "${CATTLE_AGENT_BINARY_URL}" "${CATTLE_AGENT_BINARY_LOCAL}" "${CATTLE_AGENT_BINARY_LOCAL_LOCATION}" "${BINARY_SOURCE}"
  download_rancher_file "rancher-system-agent-uninstall.sh" "script" "${CATTLE_AGENT_UNINSTALL_URL}" "${CATTLE_AGENT_UNINSTALL_LOCAL}" "${CATTLE_AGENT_UNINSTALL_LOCAL_LOCATION}" "${UNINSTALL_SOURCE}"
}

download_rancher_file() {
  name=$1
  category=$2
  url=$3
  local=$4
  local_location=$5
  source=$6

  if [ "${local}" = "true" ]; then
      info "Using local ${name} ${category} from ${local_location}"
      cp -f "${local_location}" "${CATTLE_AGENT_BIN_PREFIX}/bin/${name}"
  else
      info "Downloading ${name} ${category} from ${url}"
      if [ "${source}" != "upstream" ]; then
          CURL_BIN_CAFLAG="${CURL_CAFLAG}"
      else
          CURL_BIN_CAFLAG=""
      fi
      i=1
      while [ "${i}" -ne "${RETRYCOUNT}" ]; do
          noproxy=""
          if [ "$(in_no_proxy "${url}")" = "0" ]; then
              noproxy="--noproxy '*'"
          fi
          RESPONSE=$(curl $noproxy --connect-timeout 60 --max-time 300 --write-out "%{http_code}\n" ${CURL_BIN_CAFLAG} ${CURL_LOG} -fL "${url}" -o "${CATTLE_AGENT_BIN_PREFIX}/bin/${name}")
          case "${RESPONSE}" in
          200)
              info "Successfully downloaded the ${name} ${category}."
              break
              ;;
          *)
              i=$((i + 1))
              error "$RESPONSE received while downloading the ${name} ${category}. Sleeping for 5 seconds and trying again"
              sleep 5
              continue
              ;;
          esac
      done
      chmod +x "${CATTLE_AGENT_BIN_PREFIX}/bin/${name}"
  fi
}

check_x509_cert()
{
    cert=$1
    err=$(openssl x509 -in "${cert}" -noout 2>&1)
    if [ $? -eq 0 ]
    then
        echo ""
    else
        echo "${err}"
    fi
}

validate_ca_checksum() {
    if [ -n "${CATTLE_CA_CHECKSUM}" ]; then
        CACERT=$(mktemp)
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            noproxy=""
            if [ "$(in_no_proxy ${CATTLE_AGENT_BINARY_URL})" = "0" ]; then
                noproxy="--noproxy '*'"
            fi
            RESPONSE=$(curl $noproxy --connect-timeout 60 --max-time 60 --write-out "%{http_code}\n" --insecure ${CURL_LOG} -fL "${CATTLE_SERVER}/${CACERTS_PATH}" -o ${CACERT})
            case "${RESPONSE}" in
            200)
                info "Successfully downloaded CA certificate"
                break
                ;;
            *)
                i=$((i + 1))
                error "$RESPONSE received while downloading the CA certificate. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
        if [ ! -s "${CACERT}" ]; then
          error "The environment variable CATTLE_CA_CHECKSUM is set but there is no CA certificate configured at ${CATTLE_SERVER}/${CACERTS_PATH}"
          exit 1
        fi
        err=$(check_x509_cert "${CACERT}")
        if [ -n "${err}" ]; then
            error "Value from ${CATTLE_SERVER}/${CACERTS_PATH} does not look like an x509 certificate (${err})"
            error "Retrieved cacerts:"
            cat "${CACERT}"
            rm -f "${CACERT}"
            exit 1
        else
            info "Value from ${CATTLE_SERVER}/${CACERTS_PATH} is an x509 certificate"
        fi
        CATTLE_SERVER_CHECKSUM=$(sha256sum "${CACERT}" | awk '{print $1}')
        if [ "${CATTLE_SERVER_CHECKSUM}" != "${CATTLE_CA_CHECKSUM}" ]; then
            rm -f "${CACERT}"
            error "Configured cacerts checksum ($CATTLE_SERVER_CHECKSUM) does not match given --ca-checksum ($CATTLE_CA_CHECKSUM)"
            error "Please check if the correct certificate is configured at${CATTLE_SERVER}/${CACERTS_PATH}"
            exit 1
        fi
        CURL_CAFLAG="--cacert ${CACERT}"
    fi
}

validate_rancher_connection() {
    RANCHER_SUCCESS=false
    if [ -n "${CATTLE_SERVER}" ] && [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            noproxy=""
            if [ "$(in_no_proxy ${CATTLE_AGENT_BINARY_URL})" = "0" ]; then
                noproxy="--noproxy '*'"
            fi
            RESPONSE=$(curl $noproxy --connect-timeout 60 --max-time 60 --write-out "%{http_code}\n" ${CURL_CAFLAG} ${CURL_LOG} -fL "${CATTLE_SERVER}/healthz" -o /dev/null)
            case "${RESPONSE}" in
            200)
                info "Successfully tested Rancher connection"
                RANCHER_SUCCESS=true
                break
                ;;
            *)
                i=$((i + 1))
                error "$RESPONSE received while testing Rancher connection. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
        if [ "${RANCHER_SUCCESS}" != "true" ]; then
          fatal "Error connecting to Rancher. Perhaps --ca-checksum needs to be set?"
        fi
    fi
}

validate_ca_required() {
    CA_REQUIRED=false
    if [ -n "${CATTLE_SERVER}" ] && [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            noproxy=""
            if [ "$(in_no_proxy ${CATTLE_AGENT_BINARY_URL})" = "0" ]; then
                noproxy="--noproxy '*'"
            fi
            VERIFY_RESULT=$(curl $noproxy --connect-timeout 60 --max-time 60 --write-out "%{ssl_verify_result}\n" ${CURL_LOG} -fL "${CATTLE_SERVER}/healthz" -o /dev/null 2>/dev/null)
            CURL_EXIT="$?"
            case "${CURL_EXIT}" in
              0|60)
                case "${VERIFY_RESULT}" in
                  0)
                    info "Determined CA is not necessary to connect to Rancher"
                    CA_REQUIRED=false
                    CATTLE_CA_CHECKSUM=""
                    break
                    ;;
                  *)
                    i=$((i + 1))
                    if [ "${CURL_EXIT}" -eq "60" ]; then
                      info "Determined CA is necessary to connect to Rancher"
                      CA_REQUIRED=true
                      break
                    fi
                    error "Error received while testing necessity of CA. Sleeping for 5 seconds and trying again"
                    sleep 5
                    continue
                    ;;
                esac
                ;;
              *)
                error "Error while connecting to Rancher to verify CA necessity. Sleeping for 5 seconds and trying again."
                sleep 5
                continue
                ;;
            esac
        done
    fi
}

retrieve_connection_info() {
    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        UMASK=$(umask)
        umask 0177
        i=1
        while [ "${i}" -ne "${RETRYCOUNT}" ]; do
            noproxy=""
            if [ "$(in_no_proxy ${CATTLE_AGENT_BINARY_URL})" = "0" ]; then
                noproxy="--noproxy '*'"
            fi
            RESPONSE=$(curl $noproxy --connect-timeout 60 --max-time 60 --write-out "%{http_code}\n" ${CURL_CAFLAG} ${CURL_LOG} -H "Authorization: Bearer ${CATTLE_TOKEN}" -H "X-Cattle-Id: ${CATTLE_ID}" -H "X-Cattle-Role-Etcd: ${CATTLE_ROLE_ETCD}" -H "X-Cattle-Role-Control-Plane: ${CATTLE_ROLE_CONTROLPLANE}" -H "X-Cattle-Role-Worker: ${CATTLE_ROLE_WORKER}" -H "X-Cattle-Node-Name: ${CATTLE_NODE_NAME}" -H "X-Cattle-Address: ${CATTLE_ADDRESS}" -H "X-Cattle-Internal-Address: ${CATTLE_INTERNAL_ADDRESS}" -H "X-Cattle-Labels: ${CATTLE_LABELS}" -H "X-Cattle-Taints: ${CATTLE_TAINTS}" "${CATTLE_SERVER}"/v3/connect/agent -o ${CATTLE_AGENT_VAR_DIR}/rancher2_connection_info.json)
            case "${RESPONSE}" in
            200)
                info "Successfully downloaded Rancher connection information"
                break
                ;;
            *)
                i=$((i + 1))
                error "$RESPONSE received while downloading Rancher connection information. Sleeping for 5 seconds and trying again"
                sleep 5
                continue
                ;;
            esac
        done
        umask "${UMASK}"
    fi
}

generate_config() {
    UMASK=$(umask)
    umask 0177
cat <<-EOF >"${CATTLE_AGENT_CONFIG_DIR}/config.yaml"
workDirectory: ${CATTLE_AGENT_VAR_DIR}/work
appliedPlanDirectory: ${CATTLE_AGENT_VAR_DIR}/applied
remoteEnabled: ${CATTLE_REMOTE_ENABLED}
localEnabled: ${CATTLE_LOCAL_ENABLED}
localPlanDirectory: ${CATTLE_AGENT_VAR_DIR}/plans
preserveWorkDirectory: ${CATTLE_PRESERVE_WORKDIR}
EOF
    umask "${UMASK}"
    if [ "${CATTLE_REMOTE_ENABLED}" = "true" ]; then
        echo connectionInfoFile: ${CATTLE_AGENT_VAR_DIR}/rancher2_connection_info.json >> "${CATTLE_AGENT_CONFIG_DIR}/config.yaml"
    fi
}

generate_cattle_identifier() {
    if [ -z "${CATTLE_ID}" ]; then
        info "Generating Cattle ID"
        if [ -f "${CATTLE_AGENT_CONFIG_DIR}/cattle-id" ]; then
            CATTLE_ID=$(cat ${CATTLE_AGENT_CONFIG_DIR}/cattle-id);
            info "Cattle ID was already detected as ${CATTLE_ID}. Not generating a new one."
            return
        fi

        CATTLE_ID=$(dd if=/dev/urandom count=1 bs=512 2>/dev/null | sha256sum | awk '{print $1}' | head -c 63);
        UMASK=$(umask)
        umask 0177
        echo "${CATTLE_ID}" > ${CATTLE_AGENT_CONFIG_DIR}/cattle-id
        umask "${UMASK}"
        return
    fi
    info "Not generating Cattle ID"
}


ensure_systemd_service_stopped() {
    if systemctl is-active --quiet rancher-system-agent.service; then
        info "Rancher System Agent was detected on this host. Ensuring the rancher-system-agent is stopped."
        systemctl stop rancher-system-agent
    fi
}

create_env_file() {
    FILE_SA_ENV="/etc/systemd/system/rancher-system-agent.env"
    info "Creating environment file ${FILE_SA_ENV}"
    install -m 0600 /dev/null "${FILE_SA_ENV}"
    for i in "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY"; do
      eval v=\"\$$i\"
      if [ -z "${v}" ]; then
        env | grep -E -i "^${i}" | tee -a ${FILE_SA_ENV} >/dev/null
      else
        echo "$i=$v" | tee -a ${FILE_SA_ENV} >/dev/null
      fi
    done
}

do_install() {
    if [ $(id -u) != 0 ]; then
      fatal "This script must be run as root."
    fi

    parse_args "$@"
    setup_arch
    setup_env
    ensure_directories
    verify_downloader curl || fatal "can not find curl for downloading files"

    if [ -n "${CATTLE_CA_CHECKSUM}" ]; then
        validate_ca_required
    fi
    validate_ca_checksum
    validate_rancher_connection

    ensure_systemd_service_stopped

    download_rancher_files
    generate_config

    if [ -n "${CATTLE_TOKEN}" ]; then
        generate_cattle_identifier
        retrieve_connection_info # Only retrieve connection information from Rancher if a token was passed in.
    fi
    create_systemd_service_file
    create_env_file
    systemctl daemon-reload >/dev/null
    info "Enabling rancher-system-agent.service"
    systemctl enable rancher-system-agent
    info "Starting/restarting rancher-system-agent.service"
    systemctl restart rancher-system-agent
}

do_install "$@"
exit 0
