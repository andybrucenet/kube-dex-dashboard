#!/bin/bash
# sab-k8s.sh, ABr
# Kubernetes helpers for LMIL

########################################################################
# variables
g_rc=0

# local state data
g_state_data="$HOME/.sab-projects/sab-k8s"
[ ! -d "$g_state_data" ] && mkdir -p "$g_state_data"
[ ! -d "$g_state_data" ] && echo "No state data '$g_state_data'" && exit 2
g_state_rc_path="$g_state_data/rc"

# globals with initial state - only if authorization is enabled
g_k8s_debug=0
g_k8s_clu='1'
g_k8s_uid="$(whoami)"
g_k8s_pwd=''
g_k8s_client_token=[YOUR-TOKEN-HERE]
g_k8s_host=[YOUR-KUBERNETES-APISERVER-HOST-HERE]
g_k8s_dex_connector_id=[YOUR-DEX-CONNECTOR-ID]
g_k8s_kubectl='kubectl'
g_k8s_clu_name=''

# you can override any of the above variables.
# simply put additional code in the RC file.
if [ -s "$g_state_rc_path" ] ; then
  source "$g_state_rc_path"
  g_rc=$?
  [ $g_rc -ne 0 ] && echo "Problem sourcing data '$g_state_rc_path'" && exit $g_rc
fi

# override from environment
#set -x
[ x"$g_k8s_debug" != x ] && g_k8s_debug="$g_k8s_debug"
[ x"$SAB_K8S_CLU" != x ] && g_k8s_clu="$SAB_K8S_CLU"
[ x"$SAB_K8S_UID" != x ] && g_k8s_uid="$SAB_K8S_UID"
[ x"$SAB_K8S_PWD" != x ] && g_k8s_pwd="$SAB_K8S_PWD"
[ x"$SAB_K8S_HOST" != x ] && g_k8s_host="$SAB_K8S_HOST"
[ x"$SAB_K8S_KUBECTL" != x ] && g_k8s_kubectl="$SAB_K8S_KUBECTL"
[ x"$SAB_K8S_CLU_NAME" != x ] && g_k8s_clu_name="$SAB_K8S_CLU_NAME"

# derived values
g_k8s_full_host="${g_k8s_host}${g_k8s_clu}.hlsdev.local"
g_k8s_oauth2_uri="https://${g_k8s_full_host}:5555/"
g_k8s_login_uri="${g_k8s_oauth2_uri}login"
g_k8s_dex_uri="https://${g_k8s_full_host}:32000"

# only override if not set
[ -z "$g_k8s_clu_name" ] && g_k8s_clu_name="${g_k8s_host}${g_k8s_clu}"

########################################################################
# required tools
g_rc=0
for i in curl ; do
  if ! which $i >/dev/null 2>&1 ; then
    g_rc=$?
    echo "Missing required tool '$i'"
  fi
done
[ $g_rc -ne 0 ] && exit $g_rc
    
########################################################################
# simply ensure configuration
sab-k8s-x-config() {
  local l_var

  # step over each passed variable and write to *global* config
  for i in $@ ; do
    eval l_var=\$$i
    sed -i -e "/^$i=/d" "$g_state_rc_path"
    echo "$i='$l_var'" >> "$g_state_rc_path"
  done
  cat "$g_state_rc_path"
  return 0
}

########################################################################
# login to a dex-hosted cluster
sab-k8s-x-dex-login() {
  # vars
  local l_rc=0
  local l_work_file=''
  local l_auth_redirect=''
  local l_auth_specific=''
  local l_login_uri=''
  local l_approval=''
  local l_approval_uri=''
  local l_code_ref=''
  local l_bearer_token=''

  # a file so we can watch the progress
  l_work_file="/tmp/$$.login"

  # initial get - to setup a connection
  [ $g_k8s_debug -eq 1 ] && echo "***Initial oauth2 GET"
  curl -v -k -X GET "$g_k8s_oauth2_uri" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in initial oauth2 GET" && return $l_rc
  rm -f "$l_work_file"

  # read auth redirect first
  [ $g_k8s_debug -eq 1 ] && echo "***Initial call to '$g_k8s_login_uri'"
  curl -v -k -X POST -d "cross_client=$g_k8s_client_id" -d 'extra_scopes=openid+profile+email+groups' -d 'offline_access=yes' -e "$g_k8s_oauth2_uri" "$g_k8s_login_uri" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in auth_ref" && return $l_rc
  l_auth_redirect=$(cat "$l_work_file" | grep -e '^< Location:' | awk '{gsub(/\s/, "", $3); print $3}')
  rm -f "$l_work_file"
  [ -z "$l_auth_redirect" ] && echo 'Unable to get auth_redirect' && return 3
  [ $g_k8s_debug -eq 1 ] && echo "l_auth_redirect='$l_auth_redirect'"

  # read specific auth redirect
  [ $g_k8s_debug -eq 1 ] && echo "***Read specific auth redirect"
  curl -v -k -X GET -e "$g_k8s_oauth2_uri" "$l_auth_redirect" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in auth_ref" && return $l_rc
  l_auth_specific=$(cat "$l_work_file" | grep -e '^< Location:' | awk '{gsub(/\s/, "", $3); print $3}')
  rm -f "$l_work_file"
  [ -z "$l_auth_specific" ] && echo 'Unable to get auth_specific' && return 3
  [ $g_k8s_debug -eq 1 ] && echo "l_auth_specific='$l_auth_specific'"

  # the login page
  l_login_uri="$g_k8s_dex_uri$l_auth_specific"

  # read the login page
  [ $g_k8s_debug -eq 1 ] && echo "***Read login page"
  curl -v -k -X GET -e "$g_k8s_oauth2_uri" "$l_login_uri" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in read_login" && return $l_rc
  rm -f "$l_work_file"

  # read the password
  if [ x"$g_k8s_pwd" = x ] ; then
    >&2 echo -n "Enter password ($g_k8s_uid): "
    read -s LOCAL_PASSWORD
    l_rc=$?
    [ $l_rc -ne 0 ] && return $l_rc
    g_k8s_pwd="$LOCAL_PASSWORD"
    [ -z "$g_k8s_pwd" ] && echo 'Empty password not allowed' && return 3
    >&2 echo ''
  fi

  # login
  [ $g_k8s_debug -eq 1 ] && echo "***Issue login to '$l_login_uri'"
  curl -v -k -X POST -d "login=$g_k8s_uid" -d "password=$g_k8s_pwd" -e "$l_login_uri" "$l_login_uri" >"$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in login" && return $l_rc
  l_approval=$(cat "$l_work_file" | grep -e '^< Location:' | awk '{gsub(/\s/, "", $3); print $3}')
  rm -f "$l_work_file"
  [ -z "$l_approval" ] && echo 'Unable to get approval' && return 3
  [ $g_k8s_debug -eq 1 ] && echo "l_approval='$l_approval'"

  # submit approval
  l_approval_uri="$g_k8s_dex_uri$l_approval"
  [ $g_k8s_debug -eq 1 ] && echo "***Submit approval"
  curl -v -k -X GET -e "$l_login_uri" "$l_approval_uri" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in approval" && return $l_rc
  l_code_ref=$(cat "$l_work_file" | grep -e '^< Location:' | awk '{gsub(/\s/, "", $3); print $3}')
  rm -f "$l_work_file"
  [ -z "$l_code_ref" ] && echo 'Unable to get code_ref' && return 3
  [ $g_k8s_debug -eq 1 ] && echo "l_code_ref='$l_code_ref'"

  # submit the code ref
  [ $g_k8s_debug -eq 1 ] && echo "***Submit code_ref"
  curl -v -k -X GET -e "$l_login_uri" "$l_code_ref" > "$l_work_file" 2>&1
  l_rc=$?
  [ $g_k8s_debug -eq 1 ] && cat "$l_work_file" && echo '' && echo '' && echo ''
  [ $l_rc -ne 0 ] && rm -f "$l_work_file" && echo "Curl problem in code_ref" && return $l_rc
  l_bearer_token=$(cat "$l_work_file" | grep -e '<p> Token: <pre><code>' | sed -e 's#.*Token: <pre><code>\([^<]\+\).*#\1#')
  rm -f "$l_work_file"
  [ -z "$l_bearer_token" ] && echo 'Unable to get bearer_token' && return 3
  [ $g_k8s_debug -eq 1 ] && echo "l_bearer_token='$l_bearer_token'"

  # save result and output
  echo "$l_bearer_token"
  return 0
}

########################################################################
# show base64-encoded username for a dex-encoded cluster
sab-k8s-x-dex-username() {
  # vars
  local l_rc=0

  # length of different params
  local l_oLang=$LANG
  LANG=C
  local l_uid_len=${#g_k8s_uid}
  local l_connid_len=${#g_k8s_dex_connector_id}
  LANG=$l_oLang

  # hex codes
  local l_uid_len_hex=$(echo "obase=16; $l_uid_len" | bc)
  local l_connid_len_hex=$(echo "obase=16; $l_connid_len" | bc)
  #echo "l_uid_len='$l_uid_len'; l_uid_len_hex='$l_uid_len_hex'; l_connid_len='$l_connid_len'; l_connid_len_hex='$l_connid_len_hex'"

  # write out the raw data, base64-encoded
  local l_base64_encoded_name=$(echo -n -e \\x0A\\x${l_uid_len_hex}${g_k8s_uid}\\x12\\x${l_connid_len_hex}${g_k8s_dex_connector_id} | base64 --input -)

  # write out the entire name
  echo "${g_k8s_dex_uri}#${l_base64_encoded_name}"

  return 0
}

########################################################################
# run a customized command against a kubeadm-clu
sab-k8s-x-kubectl() {
  # vars
  local l_rc=0
  local l_kubeadm_state_dir="$g_state_data/kubeadm-clu${g_k8s_clu}"
  local l_bearer_token_file="${l_kubeadm_state_dir}/bearer"

  # other locals
  l_rc=0
  local l_tmp_file=''
  local l_bearer_token=''
  local l_idx=0
  #set -x

  # set variables
  l_tmp_file="/tmp/$$.foo"

  # state variable
  mkdir -p "$l_kubeadm_state_dir"

  # run as a loop so bearer can be outdated
  while [ $l_idx -lt 2 ] ; do
    l_idx=$((l_idx + 1))
  
    # do we already have token?
    if [ ! -s "$l_bearer_token_file" ] ; then
      # do a login
      sab-k8s-x-dex-login > "$l_tmp_file"
      l_rc=$?
      [ $l_rc -ne 0 ] && cat "$l_tmp_file" && rm -f "$l_tmp_file" && return $l_rc
      cat "$l_tmp_file" | tail -n 1 > "$l_bearer_token_file"
      rm -f "$l_tmp_file"
    fi
    l_bearer_token="$(cat "$l_bearer_token_file")"
    [ -z "$l_bearer_token" ] && echo "Unable to login" && return 1

    # create wrapper
    l_exec_file="/tmp/$$.bar"
    echo '#!/bin/bash' > "$l_exec_file"
    echo "$g_k8s_kubectl \\" > "$l_exec_file"

    # handle stuff we don't want to override
    if ! echo "$@" | grep --quiet -e '--namespace' ; then
      echo "  --namespace=$g_k8s_uid \\" >> "$l_exec_file"
    fi
    if ! echo "$@" | grep --quiet -e '--cluster' ; then
      echo "  --cluster=$g_k8s_clu_name \\" >> "$l_exec_file"
    fi

    # insert bearer
    echo "  --token='$l_bearer_token' \\" >> "$l_exec_file"

    # actual args
    echo "  $@" >> "$l_exec_file"

    # execute
    chmod +x "$l_exec_file"
    #cat "$l_exec_file"
    eval "$l_exec_file" >"$l_tmp_file" 2>&1
    l_rc=$?
    rm -f "$l_exec_file"

    # success? get out now.
    if [ $l_rc -eq 0 ] ; then
      # result
      cat "$l_tmp_file"
      rm -f "$l_tmp_file"
      return $l_rc
    fi

    # specific login problems
    if ! grep --quiet -i -e 'You must be logged in' "$l_tmp_file" 2>/dev/null ; then
      # some other error
      cat "$l_tmp_file"
      rm -f "$l_tmp_file"
      return $l_rc
    fi

    # try again - force a login
    rm -f "$l_tmp_file" "$l_bearer_token_file"
  done
}

########################################################################
# show current dex bearer token
sab-k8s-x-dex-token() {
  # vars
  local l_rc=0
  local l_kubeadm_state_dir="$g_state_data/kubeadm-clu${g_k8s_clu}"
  local l_bearer_token_file="${l_kubeadm_state_dir}/bearer"

  # other locals
  l_rc=0
  local l_tmp_file=''
  local l_bearer_token=''
  local l_idx=0
  #set -x

  # set variables
  l_tmp_file="/tmp/$$.foo"

  # state variable
  mkdir -p "$l_kubeadm_state_dir"

  # do we already have token?
  if [ ! -s "$l_bearer_token_file" ] ; then
    # do a login
    sab-k8s-x-dex-login > "$l_tmp_file"
    l_rc=$?
    [ $l_rc -ne 0 ] && cat "$l_tmp_file" && rm -f "$l_tmp_file" && return $l_rc
    cat "$l_tmp_file" | tail -n 1 > "$l_bearer_token_file"
    rm -f "$l_tmp_file"
  fi
  l_bearer_token="$(cat "$l_bearer_token_file")"
  [ -z "$l_bearer_token" ] && echo "Unable to login" && return 1

  # if we got here, we are good
  echo "$l_bearer_token"
}

########################################################################
# optional call support
l_do_run=0
if [ "x$1" != "x" ]; then
  [ "x$1" != "xsource-only" ] && l_do_run=1
fi
if [ $l_do_run -eq 1 ]; then
  l_func="$1"; shift
  [ x"$l_func" != x ] && eval sab-k8s-x-"$l_func" "$@"
fi

