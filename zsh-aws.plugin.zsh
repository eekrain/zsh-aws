#!/usr/bin/env zsh
# Standarized $0 handling, following:
# https://github.com/zdharma/Zsh-100-Commits-Club/blob/master/Zsh-Plugin-Standard.adoc
0="${ZERO:-${${0:#$ZSH_ARGZERO}:-${(%):-%N}}}"
0="${${(M)0:#/*}:-$PWD/$0}"

if [[ $PMSPEC != *b* ]] {
  PATH=$PATH:"${0:h}/bin"
}

_INPUT=
function alp() {
  [[ -r "${AWS_CONFIG_FILE:-$HOME/.aws/config}" ]] || return 1
  grep --color=never -Eo '\[.*\]' "${AWS_CONFIG_FILE:-$HOME/.aws/config}" | sed -E 's/^[[:space:]]*\[(profile)?[[:space:]]*([-_[:alnum:]\.@]+)\][[:space:]]*$/\2/g'
}

function agp() {
  echo $AWS_PROFILE
}

# AWS profile selection
function asp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    echo AWS profile cleared.
    return
  fi
  
  local -a available_profiles
  available_profiles=($(alp))
  if [[ -z "${available_profiles[(r)$1]}" ]]; then
    echo "${fg[red]}Profile '$1' not found in '${AWS_CONFIG_FILE:-$HOME/.aws/config}'" >&2
    echo "Available profiles: ${(j:, :)available_profiles:-no profiles found}${reset_color}" >&2
    return 1
  fi
  
  export AWS_DEFAULT_PROFILE=$1
  export AWS_PROFILE=$1
  export AWS_EB_PROFILE=$1
}

# AWS profile switch
function acp() {
  if [[ -z "$1" ]]; then
    unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    echo AWS profile cleared.
    return
  fi
  
  local -a available_profiles
  available_profiles=($(alp))
  if [[ -z "${available_profiles[(r)$1]}" ]]; then
    echo "${fg[red]}Profile '$1' not found in '${AWS_CONFIG_FILE:-$HOME/.aws/config}'" >&2
    echo "Available profiles: ${(j:, :)available_profiles:-no profiles found}${reset_color}" >&2
    return 1
  fi
  
  local profile="$1"
  
  # Get fallback credentials for if the aws command fails or no command is run
  local aws_access_key_id="$(aws configure get aws_access_key_id --profile $profile)"
  local aws_secret_access_key="$(aws configure get aws_secret_access_key --profile $profile)"
  local aws_session_token="$(aws configure get aws_session_token --profile $profile)"
  
  # First, if the profile has MFA configured, lets get the token and session duration
  local mfa_serial="$(aws configure get mfa_serial --profile $profile)"
  local sess_duration="$(aws configure get duration_seconds --profile $profile)"
  
  if [[ -n "$mfa_serial" ]]; then
    local -a mfa_opt
    local mfa_token
    echo -n "Please enter your MFA token for $mfa_serial: "
    read -r mfa_token
    if [[ -z "$sess_duration" ]]; then
      echo -n "Please enter the session duration in seconds (900-43200; default: 3600, which is the default maximum for a role): "
      read -r sess_duration
    fi
    mfa_opt=(--serial-number "$mfa_serial" --token-code "$mfa_token" --duration-seconds "${sess_duration:-3600}")
  fi
  
  # Now see whether we need to just MFA for the current role, or assume a different one
  local role_arn="$(aws configure get role_arn --profile $profile)"
  local sess_name="$(aws configure get role_session_name --profile $profile)"
  
  if [[ -n "$role_arn" ]]; then
    # Means we need to assume a specified role
    aws_command=(aws sts assume-role --role-arn "$role_arn" "${mfa_opt[@]}")
    
    # Check whether external_id is configured to use while assuming the role
    local external_id="$(aws configure get external_id --profile $profile)"
    if [[ -n "$external_id" ]]; then
      aws_command+=(--external-id "$external_id")
    fi
    
    # Get source profile to use to assume role
    local source_profile="$(aws configure get source_profile --profile $profile)"
    if [[ -z "$sess_name" ]]; then
      sess_name="${source_profile:-profile}"
    fi
    aws_command+=(--profile="${source_profile:-profile}" --role-session-name "${sess_name}")
    
    echo "Assuming role $role_arn using profile ${source_profile:-profile}"
  else
    # Means we only need to do MFA
    aws_command=(aws sts get-session-token --profile="$profile" "${mfa_opt[@]}")
    echo "Obtaining session token for profile $profile"
  fi
  
  # Format output of aws command for easier processing
  aws_command+=(--query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken]' --output text)
  
  # Run the aws command to obtain credentials
  local -a credentials
  credentials=(${(ps:\t:)"$(${aws_command[@]})"})
  
  if [[ -n "$credentials" ]]; then
    aws_access_key_id="${credentials[1]}"
    aws_secret_access_key="${credentials[2]}"
    aws_session_token="${credentials[3]}"
  fi
  
  # Switch to AWS profile
  if [[ -n "${aws_access_key_id}" && -n "$aws_secret_access_key" ]]; then
    export AWS_DEFAULT_PROFILE="$profile"
    export AWS_PROFILE="$profile"
    export AWS_EB_PROFILE="$profile"
    export AWS_ACCESS_KEY_ID="$aws_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$aws_secret_access_key"
    
    if [[ -n "$aws_session_token" ]]; then
      export AWS_SESSION_TOKEN="$aws_session_token"
    else
      unset AWS_SESSION_TOKEN
    fi
    
    echo "Switched to AWS Profile: $profile"
  fi
}

function acak() {
  if [[ -z "$1" ]]; then
    echo "usage: $0 <profile>"
    return 1
  fi
  
  echo "Insert the credentials when asked."
  asp "$1" || return 1
  AWS_PAGER="" aws iam create-access-key
  AWS_PAGER="" aws configure --profile "$1"
  
  echo "You can now safely delete the old access key running \`aws iam delete-access-key --access-key-id ID\`"
  echo "Your current keys are:"
  AWS_PAGER="" aws iam list-access-keys
}

function aso() {
  if command -v aws_completer &> /dev/null; then
    PROFILES=$(alp)
    
    # unset AWS_DEFAULT_PROFILE AWS_PROFILE AWS_EB_PROFILE
    _listProfiles $PROFILES
    _validateInput "Select profile by number:"
    
    SELECTED=$(echo "${PROFILES}" | head -$_INPUT)
    # echo "SELECTED: ${SELECTED}"
    # echo "_INPUT: ${_INPUT}"
    asp $SELECTED
    aws sso login --profile $SELECTED
  else
    echo "Configure SSO only can be implemented on aws-cli v2"
  fi
}

function _listProfiles(){
  profiles=$1
  k=1
  while read line
  do
    echo "${k}. ${line}";
    k=$((k + 1));
  done < <(echo "${profiles}" | tail -n 10)
}

_validateInput() {
  while true; do
    
    # Read user input
    printf $1
    read tmp
    
    echo "${k}"
    
    # If input is not an integer or if input is out of range, throw an error
    # Ask for input again
    if [[ ! $tmp =~ ^[0-9]+$ ]]; then
      echo "$fg[red]Invalid input$reset_color"
      elif [[ "$tmp" -lt "1" ]] || [[ "$tmp" -gt $((k)) ]]; then
      echo "$fg[red]Input out of range $reset_color"
    else
      _INPUT=$tmp
      break
    fi
  done
}

function _aws_profiles() {
  reply=($(alp))
}
compctl -K _aws_profiles asp acp acak

# AWS prompt
function aws_prompt_info() {
  [[ -z $AWS_PROFILE ]] && return
  echo "${ZSH_THEME_AWS_PREFIX:=<aws:}${AWS_PROFILE}${ZSH_THEME_AWS_SUFFIX:=>}"
}

if [[ "$SHOW_AWS_PROMPT" != false && "$RPROMPT" != *'$(aws_prompt_info)'* ]]; then
  RPROMPT='$(aws_prompt_info)'"$RPROMPT"
fi


# Load awscli completions

# AWS CLI v2 comes with its own autocompletion. Check if that is there, otherwise fall back
if command -v aws_completer &> /dev/null; then
  complete -C aws_completer aws
else
  function _awscli-homebrew-installed() {
    # check if Homebrew is installed
    (( $+commands[brew] )) || return 1
    
    # speculatively check default brew prefix
    if [ -h /usr/local/opt/awscli ]; then
      _brew_prefix=/usr/local/opt/awscli
    else
      # ok, it is not in the default prefix
      # this call to brew is expensive (about 400 ms), so at least let's make it only once
      _brew_prefix=$(brew --prefix awscli)
    fi
  }
  
  # get aws_zsh_completer.sh location from $PATH
  _aws_zsh_completer_path="$commands[aws_zsh_completer.sh]"
  
  # otherwise check common locations
  if [[ -z $_aws_zsh_completer_path ]]; then
    # Homebrew
    if _awscli-homebrew-installed; then
      _aws_zsh_completer_path=$_brew_prefix/libexec/bin/aws_zsh_completer.sh
      # Ubuntu
      elif [[ -e /usr/share/zsh/vendor-completions/_awscli ]]; then
      _aws_zsh_completer_path=/usr/share/zsh/vendor-completions/_awscli
      # NixOS
      elif [[ -e "${commands[aws]:P:h:h}/share/zsh/site-functions/aws_zsh_completer.sh" ]]; then
      _aws_zsh_completer_path="${commands[aws]:P:h:h}/share/zsh/site-functions/aws_zsh_completer.sh"
      # RPM
    else
      _aws_zsh_completer_path=/usr/share/zsh/site-functions/aws_zsh_completer.sh
    fi
  fi
  
  [[ -r $_aws_zsh_completer_path ]] && source $_aws_zsh_completer_path
  unset _aws_zsh_completer_path _brew_prefix
fi