#!/bin/bash

CONFIG_FILE="$HOME/.ssm/config.json"
# `ssm db` maps <db>.tunnel to 127.0.0.1 here. SSM_HOSTS_FILE exists for
# test/commands_test.sh, which points it at a scratch copy.
HOSTS_FILE="${SSM_HOSTS_FILE:-/etc/hosts}"
# One lease file per running `ssm db`, so parallel tunnels to the same database
# share the hosts line and only the last one to close removes it.
TUNNEL_DIR="$HOME/.ssm/tunnels"
# The release workflow rewrites this line to the release tag (stamp_version in
# .github/scripts/release.sh), so it must stay exactly SSM_VERSION="dev" here.
SSM_VERSION="v1.2.7"
# Set by the dispatch block at the bottom. Only used to name the command in
# error and usage messages.
COMMAND=""

# Uninstall is exempt: jq may already be gone, and removing ssm must still work.
if [[ "${1:-}" != "uninstall" ]] && ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: brew install jq"
  exit 1
fi

# ---------------------------------------------------------------------------
# Terminal styling. Color is on only when stdout is a terminal, so piped or
# redirected output stays plain text; NO_COLOR turns it off everywhere.
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW=""
fi

load_config() {
  jq -r ".[\"$1\"][\"$2\"]" "$CONFIG_FILE"
}

list_accounts() {
  jq -r 'keys[]' "$CONFIG_FILE"
}

select_menu() {
  local prompt="$1"
  shift
  select_menu_header "$prompt" "" "$@"
}

# select_menu_header <prompt> <header> item...
# select_menu with a line of help above the list; an empty header draws none.
select_menu_header() {
  local prompt="$1" header="$2"
  shift 2
  local items=("$@")

  # Checked here rather than at startup: a fully-flagged run never opens a menu,
  # and neither do `ssm help` or `ssm update`.
  if ! command -v fzf &>/dev/null; then
    echo "Error: fzf is required but not installed. Run: brew install fzf" >&2
    return 1
  fi

  if [[ -n "$header" ]]; then
    printf '%s\n' "${items[@]}" |
      fzf --prompt="$prompt " --header="$header" --height=~15 --layout=reverse --border
  else
    printf '%s\n' "${items[@]}" | fzf --prompt="$prompt " --height=~10 --layout=reverse --border
  fi
}

# print_choice <label> <value>
#
# fzf clears its menu once you pick, so without this nothing on screen says
# what was chosen. One line on stderr per choice: callers run inside $( ).
# Tabs in a menu row become spaces here.
print_choice() {
  local label="$1" value="$2" mark="*"
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) mark="✓" ;;
  esac
  label="$(printf '%s' "${label:0:1}" | tr '[:lower:]' '[:upper:]')${label:1}"
  printf '%s%s %s:%s %s\n' "${C_BOLD}${C_GREEN}" "$mark" "$label" "$C_RESET" \
    "$(printf '%s' "$value" | tr '\t' ' ')" >&2
}

# select_multi <prompt> <header> row...
#
# Checklist counterpart of select_menu. Each row is "key<TAB>label"; prints the
# key of every row picked, one per line, and returns 1 if the menu is cancelled.
#
# fzf prints the row under the cursor when Enter is pressed with nothing marked,
# so a "none" row goes first: pressing Enter straight away picks nothing. With
# no fzf at all -- uninstall can run after it is gone -- each row becomes a y/N
# question instead.
select_multi() {
  local prompt="$1" header="$2"
  shift 2
  local row answer picked

  if ! command -v fzf &>/dev/null; then
    for row in "$@"; do
      read -r -p "$prompt ${row#*$'\t'} [y/N]: " answer
      [[ "$answer" == "y" || "$answer" == "Y" ]] && printf '%s\n' "${row%%$'\t'*}"
    done
    return 0
  fi

  picked=$({ printf 'none\tNothing -- keep all of these\n'; printf '%s\n' "$@"; } \
    | fzf --multi --prompt="$prompt " --header="$header" --delimiter=$'\t' --with-nth=2.. \
          --height=~15 --layout=reverse --border) || return 1
  printf '%s\n' "$picked" | cut -f1 | grep -v '^none$'
  return 0
}

# Draws the "connect to this, not to that" box for `ssm db`. The tunnel endpoint
# is the whole point of the command and used to scroll past as one plain line,
# so it is boxed, colored, and shown next to the real endpoint it replaces.
#
# Padding is measured on the label and the value alone: ${#var} counts an escape
# sequence as characters, so measuring the colored string would pull the right
# border left by exactly the length of the escapes.
print_tunnel_banner() {
  local host="$1" port="$2" real_host="$3" real_port="$4"
  local tl tr bl br ml mr hz vt ell dash

  # The line-drawing glyphs are mojibake outside a UTF-8 locale.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*)
      tl="┌" tr="┐" bl="└" br="┘" ml="├" mr="┤" hz="─" vt="│" ell="…" dash="—" ;;
    *)
      tl="+" tr="+" bl="+" br="+" ml="+" mr="+" hz="-" vt="|" ell="..." dash="-" ;;
  esac

  # COLUMNS is unset or 0 in a non-interactive shell, so an implausible value
  # falls through to tput and then to a default rather than to a tiny box.
  local cols="${COLUMNS:-0}"
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -ge 20 ]] || cols=$(tput cols 2>/dev/null)
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -ge 20 ]] || cols=80
  # Two border characters plus a space of padding on each side.
  local max_inner=$((cols - 4))
  [[ "$max_inner" -ge 28 ]] || max_inner=28

  local title="DB TUNNEL $dash connect using THESE values"

  # Rows are held as label / value / color so the value can be truncated and
  # colored without the label or the escapes skewing the measured width.
  local labels=() values=() colors=()
  labels+=("Host  ") values+=("$host")               colors+=("${C_BOLD}${C_GREEN}")
  labels+=("Port  ") values+=("$port")               colors+=("${C_BOLD}${C_GREEN}")
  labels+=("")       values+=("")                    colors+=("")
  labels+=("")       values+=("real endpoint, do NOT use directly:") colors+=("$C_DIM")
  labels+=("  ")     values+=("${real_host}:${real_port}")           colors+=("$C_DIM")

  [[ ${#title} -le $max_inner ]] || title="${title:0:$((max_inner - ${#ell}))}$ell"

  local i n inner=${#title} room width
  n=${#labels[@]}
  for ((i = 0; i < n; i++)); do
    room=$((max_inner - ${#labels[i]}))
    if [[ ${#values[i]} -gt $room ]]; then
      values[i]="${values[i]:0:$((room - ${#ell}))}$ell"
    fi
    width=$((${#labels[i]} + ${#values[i]}))
    [[ $width -le $inner ]] || inner=$width
  done

  local rule="" j
  for ((j = 0; j < inner + 2; j++)); do rule="$rule$hz"; done

  local pad
  printf '%s%s%s\n' "$tl" "$rule" "$tr"
  pad=$(printf '%*s' $((inner - ${#title})) '')
  printf '%s %s%s%s%s %s\n' "$vt" "${C_BOLD}${C_YELLOW}" "$title" "$C_RESET" "$pad" "$vt"
  printf '%s%s%s\n' "$ml" "$rule" "$mr"
  for ((i = 0; i < n; i++)); do
    pad=$(printf '%*s' $((inner - ${#labels[i]} - ${#values[i]})) '')
    if [[ -n "${colors[i]}" ]]; then
      printf '%s %s%s%s%s%s %s\n' \
        "$vt" "${labels[i]}" "${colors[i]}" "${values[i]}" "$C_RESET" "$pad" "$vt"
    else
      printf '%s %s%s%s %s\n' "$vt" "${labels[i]}" "${values[i]}" "$pad" "$vt"
    fi
  done
  printf '%s%s%s\n' "$bl" "$rule" "$br"
}

# ---------------------------------------------------------------------------
# Argument handling. Every interactive prompt has a flag that replaces it; a
# flag you leave out falls back to its menu, so bare `ssm ssh` is unchanged.
# ---------------------------------------------------------------------------

# Every flag the script knows about, in any command. parse_args clears all of
# them on entry so a second call in the same shell starts clean.
ALL_ARG_FLAGS="env app type instance container task host db cluster namespace \
pod profile region access-key secret-key skip-credentials yes delete-profile \
name port force purge with-deps"

# --access-key -> ARG_ACCESS_KEY
arg_var() {
  local name="${1#--}"
  name=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  printf 'ARG_%s' "$name"
}

# Short and legacy spellings resolve to one canonical flag.
normalize_flag() {
  case "$1" in
    -e|--account) printf '%s' "--env" ;;
    -n)           printf '%s' "--namespace" ;;
    -c)           printf '%s' "--container" ;;
    -h)           printf '%s' "--help" ;;
    *)            printf '%s' "$1" ;;
  esac
}

die_usage() {
  echo "Error: $1" >&2
  echo "" >&2
  usage_for "$COMMAND" >&2
  return 1
}

# parse_args "<value-flags>" "<bool-flags>" "$@"
#
# Sets ARG_<UPPER_SNAKE> globals -- --app adam sets ARG_APP, --host sets
# ARG_HOST=1. Each command passes only the flags it accepts, so a flag that
# belongs to another command is rejected instead of silently ignored.
parse_args() {
  local value_flags=" $1 " bool_flags=" $2 "
  shift 2

  local name
  for name in $ALL_ARG_FLAGS; do
    unset "$(arg_var "--$name")"
  done

  while [[ $# -gt 0 ]]; do
    local raw="$1" key val has_val=0
    val=""
    case "$raw" in
      --*=*) key="${raw%%=*}"; val="${raw#*=}"; has_val=1 ;;
      *)     key="$raw" ;;
    esac
    key=$(normalize_flag "$key")

    if [[ "$key" == "--help" ]]; then
      usage_for "$COMMAND"
      exit 0
    fi

    if [[ "$bool_flags" == *" $key "* ]]; then
      [[ $has_val -eq 1 ]] && { die_usage "Option $key takes no value."; return 1; }
      printf -v "$(arg_var "$key")" '%s' "1"
      shift
    elif [[ "$value_flags" == *" $key "* ]]; then
      if [[ $has_val -eq 0 ]]; then
        [[ $# -lt 2 ]] && { die_usage "Option $key requires a value."; return 1; }
        val="$2"
        shift
      fi
      # A bare "-" is a real value for --secret-key (read stdin). Anything else
      # starting with a dash is a missing value, not a value.
      if [[ -z "$val" || ( "$val" == -* && "$val" != "-" ) ]]; then
        die_usage "Option $key requires a value."
        return 1
      fi
      printf -v "$(arg_var "$key")" '%s' "$val"
      shift
    else
      die_usage "Unknown option '$raw' for ssm ${COMMAND:-<command>}."
      return 1
    fi
  done
}

# resolve_selection <wanted> <label> <context> <prompt> <match-fields> <auto> row...
#
#   wanted        the flag value; "" means ask interactively
#   context       where we looked, for the error message
#   match-fields  comma-separated 1-based tab-field numbers to match <wanted>
#                 against, so an instance matches on either its id or its Name
#   auto          "auto" to auto-select when there is exactly one candidate
#
# Echoes the chosen row; the caller splits out the columns it wants. Returns 1
# rather than exiting, because callers run it inside $( ) where an exit would
# only kill the subshell.
resolve_selection() {
  local wanted="$1" label="$2" context="$3" prompt="$4" fields="$5" auto="$6"
  shift 6
  local rows=("$@")

  if [[ -z "$wanted" ]]; then
    if [[ ${#rows[@]} -eq 1 && "$auto" == "auto" ]]; then
      print_choice "$label" "${rows[0]} (only one)"
      printf '%s\n' "${rows[0]}"
      return 0
    fi
    local picked
    picked=$(select_menu "$prompt" "${rows[@]}") || return 1
    [[ -n "$picked" ]] && print_choice "$label" "$picked"
    printf '%s\n' "$picked"
    return 0
  fi

  local matches=() row field
  for row in "${rows[@]}"; do
    for field in ${fields//,/ }; do
      if [[ "$(printf '%s' "$row" | cut -d"$(printf '\t')" -f"$field")" == "$wanted" ]]; then
        matches+=("$row")
        break
      fi
    done
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    print_choice "$label" "${matches[0]}"
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "Error: no $label '$wanted' in $context." >&2
    echo "Available:" >&2
    printf '  %s\n' "${rows[@]}" >&2
  else
    echo "Error: ambiguous $label '$wanted' in $context. Matches:" >&2
    printf '  %s\n' "${matches[@]}" >&2
  fi
  return 1
}

# Secrets never come from a flag value -- that puts them in shell history and in
# `ps` output. Env var first, then one line on stdin via `--secret-key -`, then
# a hidden prompt.
read_secret_value() {
  local flag="$1" secret

  if [[ -n "$SSM_AWS_SECRET_KEY" ]]; then
    printf '%s' "$SSM_AWS_SECRET_KEY"
    return 0
  fi

  if [[ -n "$flag" ]]; then
    if [[ "$flag" != "-" ]]; then
      echo "Error: --secret-key takes no literal value; it would be recorded in your shell history." >&2
      echo "Use SSM_AWS_SECRET_KEY=... or '--secret-key -' to read one line from stdin." >&2
      return 1
    fi
    IFS= read -r secret
    printf '%s' "$secret"
    return 0
  fi

  read -r -s -p "Secret Access Key: " secret
  echo "" >&2
  printf '%s' "$secret"
}

list_apps() {
  local profile="$1" region="$2"
  aws ec2 describe-instances \
    --profile "$profile" \
    --region "$region" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].Tags[?Key==`App`].Value[]' \
    --output text | tr '\t' '\n' | sort -u | grep -v -e '^$' -e '^None$'
}

list_instances() {
  local profile="$1" region="$2" app="$3"
  aws ec2 describe-instances \
    --profile "$profile" \
    --region "$region" \
    --filters "Name=tag:App,Values=$app" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`].Value|[0]]' \
    --output text
}

list_rds_instances() {
  local profile="$1" region="$2" app="$3"
  aws rds describe-db-instances \
    --profile "$profile" \
    --region "$region" \
    --query "DBInstances[?TagList[?Key=='App' && Value=='$app']].[DBInstanceIdentifier, Endpoint.Address, Endpoint.Port]" \
    --output text
}

# ---------------------------------------------------------------------------
# ECS support. Everything below is additive: on an account with no ECS these
# helpers return nothing and every EC2 code path behaves exactly as before.
# ---------------------------------------------------------------------------

# Populated once per run by discover_ecs_services. One "cluster<TAB>service<TAB>app"
# line per App-tagged ECS service. Empty when the account has no ECS.
ECS_SERVICES=""
ECS_DISCOVERY_DONE=""

discover_ecs_services_slow() {
  local profile="$1" region="$2"
  local clusters cluster services batch

  clusters=$(aws ecs list-clusters \
    --profile "$profile" \
    --region "$region" \
    --query 'clusterArns[]' \
    --output text 2>/dev/null | tr '\t' '\n')
  [[ -z "$clusters" ]] && return 0

  while IFS= read -r cluster; do
    [[ -z "$cluster" || "$cluster" == "None" ]] && continue

    services=$(aws ecs list-services \
      --profile "$profile" \
      --region "$region" \
      --cluster "$cluster" \
      --query 'serviceArns[]' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v -e '^$' -e '^None$')
    [[ -z "$services" ]] && continue

    # describe-services takes at most 10 services per call.
    while IFS= read -r batch; do
      [[ -z "$batch" ]] && continue
      aws ecs describe-services \
        --profile "$profile" \
        --region "$region" \
        --cluster "$cluster" \
        --services $batch \
        --include TAGS \
        --query 'services[].[clusterArn, serviceName, tags[?key==`App`].value|[0]]' \
        --output text 2>/dev/null \
        | awk -F'\t' '$3 != "" && $3 != "None" { n = split($1, p, "/"); print p[n] "\t" $2 "\t" $3 }'
    done < <(echo "$services" | xargs -n 10)
  done <<< "$clusters"
}

discover_ecs_services() {
  local profile="$1" region="$2"
  [[ -n "$ECS_DISCOVERY_DONE" ]] && return 0
  ECS_DISCOVERY_DONE=1

  # Fast path: one call to the Resource Groups Tagging API. Service ARNs are
  # arn:aws:ecs:<region>:<acct>:service/<cluster>/<service>, so cluster and
  # service both fall out of the ARN.
  local raw rc
  raw=$(aws resourcegroupstaggingapi get-resources \
    --profile "$profile" \
    --region "$region" \
    --tag-filters Key=App \
    --resource-type-filters ecs:service \
    --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`App`].Value|[0]]' \
    --output text 2>/dev/null)
  rc=$?

  if [[ $rc -eq 0 ]]; then
    ECS_SERVICES=$(echo "$raw" | awk -F'\t' '
      $2 != "" && $2 != "None" {
        n = split($1, p, "/")
        if (n >= 3) print p[n-1] "\t" p[n] "\t" $2
      }')
    return 0
  fi

  # Slower fallback for accounts without tag:GetResources. Stay silent unless it
  # actually turned something up, so a pure-EC2 account sees no new output.
  ECS_SERVICES=$(discover_ecs_services_slow "$profile" "$region")
  [[ -n "$ECS_SERVICES" ]] && \
    echo "Note: tagging API unavailable, enumerated ECS services instead." >&2
  return 0
}

list_ecs_apps() {
  [[ -z "$ECS_SERVICES" ]] && return 0
  echo "$ECS_SERVICES" | awk -F'\t' 'NF >= 3 { print $3 }'
}

ecs_services_for_app() {
  local app="$1"
  [[ -z "$ECS_SERVICES" ]] && return 0
  echo "$ECS_SERVICES" | awk -F'\t' -v app="$app" '$3 == app { print $1 "\t" $2 }'
}

# Is this EC2 instance registered as an ECS container instance? Echoes
# "cluster<TAB>containerInstanceArn" on a hit and nothing on a miss. A missing
# ECS policy is treated as a miss so it can never block an EC2 login.
detect_ecs_container_instance() {
  local profile="$1" region="$2" instance_id="$3"
  local clusters cluster arn

  clusters=$(aws ecs list-clusters \
    --profile "$profile" \
    --region "$region" \
    --query 'clusterArns[]' \
    --output text 2>/dev/null | tr '\t' '\n')
  [[ -z "$clusters" ]] && return 0

  while IFS= read -r cluster; do
    [[ -z "$cluster" || "$cluster" == "None" ]] && continue
    arn=$(aws ecs list-container-instances \
      --profile "$profile" \
      --region "$region" \
      --cluster "$cluster" \
      --filter "ec2InstanceId == '$instance_id'" \
      --query 'containerInstanceArns[0]' \
      --output text 2>/dev/null)
    if [[ -n "$arn" && "$arn" != "None" ]]; then
      printf '%s\t%s\n' "${cluster##*/}" "$arn"
      return 0
    fi
  done <<< "$clusters"
}

# One row per running container:
#   taskId<TAB>container<TAB>launchType<TAB>exec:on|exec:off<TAB>cluster
list_ecs_task_rows() {
  local profile="$1" region="$2" cluster="$3"
  shift 3
  [[ $# -eq 0 ]] && return 0

  aws ecs describe-tasks \
    --profile "$profile" \
    --region "$region" \
    --cluster "$cluster" \
    --tasks "$@" \
    --query 'tasks[?lastStatus==`RUNNING`].[taskArn, launchType, enableExecuteCommand, containers[].name]' \
    --output json 2>/dev/null \
    | jq -r --arg cluster "$cluster" '
        .[] | . as $t
        | ($t[0] | split("/") | last) as $id
        | $t[3][]
        | [$id, ., ($t[1] // "-"), (if $t[2] then "exec:on" else "exec:off" end), $cluster]
        | @tsv'
}

ecs_exec() {
  local profile="$1" region="$2" cluster="$3" task="$4" container="$5"

  if ! command -v session-manager-plugin &>/dev/null; then
    echo "Error: session-manager-plugin is required for ECS Exec." >&2
    echo "Re-run the installer to add it: bash install.sh" >&2
    exit 1
  fi

  echo "" >&2
  echo "Connecting to container $container in task $task via ECS Exec ..."
  # Pick the shell inside the container rather than retrying out here:
  # `aws ecs execute-command` exits 0 even when the requested shell is missing
  # (it only prints "Unable to start command"), so an outer retry never fires.
  aws ecs execute-command \
    --profile "$profile" \
    --region "$region" \
    --cluster "$cluster" \
    --task "$task" \
    --container "$container" \
    --interactive \
    --command "/bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'"
}

ecs_pick_and_exec() {
  local profile="$1" region="$2" want_container="$3" want_task="$4"
  shift 4
  local rows=("$@")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running ECS tasks found." >&2
    exit 1
  fi

  # --task narrows the rows first, so --container only has to be unique within
  # the task the user named.
  if [[ -n "$want_task" ]]; then
    local kept=() row
    for row in "${rows[@]}"; do
      [[ "$(printf '%s' "$row" | cut -d"$(printf '\t')" -f1)" == "$want_task" ]] && kept+=("$row")
    done
    if [[ ${#kept[@]} -eq 0 ]]; then
      echo "Error: no task '$want_task' among the running tasks." >&2
      echo "Available:" >&2
      printf '  %s\n' "${rows[@]}" >&2
      exit 1
    fi
    rows=("${kept[@]}")
  fi

  local selected
  if ! selected=$(resolve_selection "$want_container" "container" "the running tasks" \
      "Select container:" 2 auto "${rows[@]}"); then
    [[ -n "$want_container" ]] && echo "Narrow it further with --task <id>." >&2
    exit 1
  fi
  [[ -z "$selected" ]] && exit 0

  local task container exec_flag cluster
  task=$(echo "$selected" | awk -F'\t' '{print $1}')
  container=$(echo "$selected" | awk -F'\t' '{print $2}')
  exec_flag=$(echo "$selected" | awk -F'\t' '{print $4}')
  cluster=$(echo "$selected" | awk -F'\t' '{print $5}')

  if [[ "$exec_flag" == "exec:off" ]]; then
    echo "" >&2
    echo "ECS Exec is not enabled for this task." >&2
    echo "Enable it on the service and redeploy:" >&2
    echo "  aws ecs update-service --cluster $cluster --service <service> \\" >&2
    echo "    --enable-execute-command --force-new-deployment" >&2
    echo "" >&2
    echo "The task role also needs ssmmessages:CreateControlChannel," >&2
    echo "CreateDataChannel, OpenControlChannel and OpenDataChannel." >&2
    exit 1
  fi

  ecs_exec "$profile" "$region" "$cluster" "$task" "$container"
}

# Fargate / service path: every running task of the app's ECS services.
ssh_ecs_app() {
  local profile="$1" region="$2" app="$3"
  echo "Fetching ECS tasks for $app..." >&2

  local rows=() cluster service tasks line
  while IFS=$'\t' read -r cluster service; do
    [[ -z "$cluster" || -z "$service" ]] && continue
    tasks=$(aws ecs list-tasks \
      --profile "$profile" \
      --region "$region" \
      --cluster "$cluster" \
      --service-name "$service" \
      --desired-status RUNNING \
      --query 'taskArns[]' \
      --output text 2>/dev/null)
    [[ -z "$tasks" || "$tasks" == "None" ]] && continue

    while IFS= read -r line; do
      [[ -n "$line" ]] && rows+=("$line")
    done < <(list_ecs_task_rows "$profile" "$region" "$cluster" $tasks)
  done < <(ecs_services_for_app "$app")

  ecs_pick_and_exec "$profile" "$region" "$ARG_CONTAINER" "$ARG_TASK" "${rows[@]}"
}

# ECS-on-EC2 path: the tasks running on one container instance.
ssh_ecs_container_instance() {
  local profile="$1" region="$2" cluster="$3" ci_arn="$4"
  echo "Fetching tasks on this container instance..." >&2

  local tasks rows=() line
  tasks=$(aws ecs list-tasks \
    --profile "$profile" \
    --region "$region" \
    --cluster "$cluster" \
    --container-instance "$ci_arn" \
    --desired-status RUNNING \
    --query 'taskArns[]' \
    --output text 2>/dev/null)

  if [[ -z "$tasks" || "$tasks" == "None" ]]; then
    echo "No running tasks on this container instance." >&2
    exit 1
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_ecs_task_rows "$profile" "$region" "$cluster" $tasks)

  ecs_pick_and_exec "$profile" "$region" "$ARG_CONTAINER" "$ARG_TASK" "${rows[@]}"
}

find_free_port() {
  local port="$1"
  local used_ports
  used_ports=$(jq -r '[.. | numbers] | .[]' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ')
  while lsof -i :"$port" &>/dev/null || echo " $used_ports " | grep -qw "$port"; do
    ((port++))
  done
  echo "$port"
}

get_db_port() {
  local account="$1" db_identifier="$2"
  local port
  port=$(jq -r ".[\"$account\"].databases[\"$db_identifier\"] // empty" "$CONFIG_FILE")
  if [[ -z "$port" ]]; then
    port=$(find_free_port 15432)
    local updated
    updated=$(jq ".[\"$account\"].databases[\"$db_identifier\"] = $port" "$CONFIG_FILE")
    echo "$updated" > "$CONFIG_FILE"
    echo "Assigned port $port to $db_identifier" >&2
  fi
  echo "$port"
}

# ---------------------------------------------------------------------------
# The hosts entry behind `ssm db`. Only a line ssm wrote itself -- exactly
# "127.0.0.1 <alias> # ssm-tunnel" -- is ever removed, and only once no other
# running tunnel holds a lease on that alias. Lines are compared as whole
# strings, never as a regex: an unanchored sed pattern with unescaped dots is
# what used to take neighbouring entries with it.
# ---------------------------------------------------------------------------

HOSTS_TAG="# ssm-tunnel"

hosts_line() {
  printf '127.0.0.1 %s %s' "$1" "$HOSTS_TAG"
}

# True when any line already maps 127.0.0.1 to exactly this name -- ours, or
# one the user wrote -- so a second entry is never added.
hosts_has_entry() {
  awk -v name="$1" '
    { sub(/#.*/, "") }
    $1 == "127.0.0.1" { for (i = 2; i <= NF; i++) if ($i == name) { found = 1; exit } }
    END { exit !found }' "$HOSTS_FILE"
}

hosts_add_entry() {
  local line
  line=$(hosts_line "$1")
  # A file without a final newline would glue our line onto its last one.
  if [[ -s "$HOSTS_FILE" && -n "$(tail -c 1 "$HOSTS_FILE")" ]]; then
    line=$'\n'"$line"
  fi
  printf '%s\n' "$line" | sudo tee -a "$HOSTS_FILE" > /dev/null
}

# Copies over the file rather than renaming onto it, so /etc/hosts keeps its
# inode, owner and mode.
hosts_remove_entry() {
  local line tmp rc
  line=$(hosts_line "$1")
  grep -qxF -- "$line" "$HOSTS_FILE" || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/ssm-hosts.XXXXXX") || return 1
  awk -v line="$line" '$0 != line' "$HOSTS_FILE" > "$tmp" && sudo cp "$tmp" "$HOSTS_FILE"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# mkdir is atomic, and macOS has no flock. A lock older than a minute or so
# belongs to an ssm that was killed while holding it.
tunnel_lock() {
  local lock="$TUNNEL_DIR/.lock" tries=0
  mkdir -p "$TUNNEL_DIR" 2>/dev/null || return 1
  until mkdir "$lock" 2>/dev/null; do
    if [[ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      rmdir "$lock" 2>/dev/null
      continue
    fi
    tries=$((tries + 1))
    [[ $tries -ge 50 ]] && return 1
    sleep 0.1
  done
}

tunnel_unlock() {
  rmdir "$TUNNEL_DIR/.lock" 2>/dev/null
}

# Prints how many running tunnels hold a lease on the alias, deleting the
# leases of any whose process is gone.
tunnel_live_leases() {
  local alias="$1" f pid n=0
  for f in "$TUNNEL_DIR/$alias".*; do
    [[ -e "$f" ]] || continue
    pid="${f##*.}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      n=$((n + 1))
    else
      rm -f "$f"
    fi
  done
  echo "$n"
}

tunnel_acquire() {
  local alias="$1" locked=0
  tunnel_lock && locked=1
  tunnel_live_leases "$alias" > /dev/null
  touch "$TUNNEL_DIR/$alias.$$" 2>/dev/null
  if ! hosts_has_entry "$alias"; then
    echo "Adding $alias to $HOSTS_FILE (requires sudo) ..."
    hosts_add_entry "$alias"
  fi
  [[ $locked -eq 1 ]] && tunnel_unlock
  return 0
}

tunnel_release() {
  local alias="$1"
  if ! tunnel_lock; then
    rm -f "$TUNNEL_DIR/$alias.$$"
    echo "Could not lock $TUNNEL_DIR; leaving $alias in $HOSTS_FILE." >&2
    return 1
  fi
  rm -f "$TUNNEL_DIR/$alias.$$"
  if ! grep -qxF -- "$(hosts_line "$alias")" "$HOSTS_FILE"; then
    : # Not ours: absent, or written by the user.
  elif [[ "$(tunnel_live_leases "$alias")" -gt 0 ]]; then
    echo "Leaving $alias in $HOSTS_FILE: another ssm db tunnel is still using it."
  else
    echo "Removing $alias from $HOSTS_FILE ..."
    hosts_remove_entry "$alias"
  fi
  tunnel_unlock
}

# Each row carries the account's masked access key, so two accounts with
# similar names can be told apart. Matching is on the name alone (field 1),
# and only the name is printed, so callers never see the hint.
pick_account() {
  local wanted="$1"
  local accounts=() name profile table selected
  table=$(aws_profile_keys)
  while IFS=$'\t' read -r name profile; do
    [[ -n "$name" ]] && accounts+=("$name"$'\t'"$(key_hint_for "$table" "$profile")")
  done < <(jq -r 'keys[] as $k | [$k, (.[$k].profile // "")] | @tsv' "$CONFIG_FILE")

  if [[ ${#accounts[@]} -eq 0 ]]; then
    echo "No accounts found in $CONFIG_FILE" >&2
    return 1
  fi

  selected=$(resolve_selection "$wanted" "account" "$CONFIG_FILE" "Select account:" 1 "" \
    "${accounts[@]}") || return 1
  printf '%s\n' "${selected%%$'\t'*}"
}

# ---------------------------------------------------------------------------
# AWS CLI profiles and regions, for `ssm config add` and `ssm config edit`.
# ---------------------------------------------------------------------------

# Prints "profile<TAB>access-key-id" for every profile in the AWS CLI's shared
# files, key empty for a profile without one (SSO, assumed role). The files are
# read directly -- one awk, where `aws configure get` per profile would cost a
# Python start-up each and make every account menu slow to open.
aws_profile_keys() {
  local cred="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  local conf="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  local files=()
  [[ -f "$cred" ]] && files+=("$cred")
  [[ -f "$conf" ]] && files+=("$conf")
  [[ ${#files[@]} -eq 0 ]] && return 0

  awk -v cred="$cred" '
    function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
    /^[ \t]*\[/ {
      s = $0
      sub(/^[ \t]*\[/, "", s); sub(/\][ \t\r]*$/, "", s); s = trim(s)
      # ~/.aws/config names a profile "[profile x]", except "[default]"; its
      # other sections ([sso-session x], [services x]) are not profiles.
      if (FILENAME != cred && s != "default") {
        if (s !~ /^profile[ \t]+/) { cur = ""; next }
        sub(/^profile[ \t]+/, "", s)
      }
      cur = s
      if (!(cur in seen)) { seen[cur] = 1; order[++n] = cur }
      next
    }
    cur != "" && /^[ \t]*aws_access_key_id[ \t]*=/ {
      v = $0; sub(/^[^=]*=/, "", v); v = trim(v)
      # The credentials file wins, as it does for the CLI.
      if (!(cur in key) || FILENAME == cred) key[cur] = v
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], key[order[i]] }
  ' "${files[@]}" | LC_ALL=C sort
}

# key_hint_for <aws_profile_keys output> <profile> -> "(AKIA****WXYZ)"
key_hint_for() {
  printf '%s\n' "$1" | awk -F'\t' -v p="$2" '
    p != "" && $1 == p { found = 1; key = $2; exit }
    END {
      if (!found) print "(no such AWS profile)"
      else if (key == "") print "(no access key)"
      else if (length(key) < 8) print "(****)"
      else print "(" substr(key, 1, 4) "****" substr(key, length(key) - 3) ")"
    }'
}

aws_profile_exists() {
  aws_profile_keys | cut -f1 | grep -qxF -- "$1"
}

# The characters that survive an INI section header and a --profile argument.
# A profile that already exists is accepted whatever its name.
validate_profile_name() {
  local profile="$1"
  [[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]] && return 0
  aws_profile_exists "$profile" && return 0
  echo "Error: '$profile' is not a valid AWS CLI profile name." >&2
  echo "Use letters, digits and . _ - @ +, starting with a letter or digit." >&2
  return 1
}

# pick_profile <wanted>
#
# The existing profiles, each with its masked key, plus whatever you type: a
# name that matches nothing is taken as a new profile to create. fzf reports
# that as exit 1 with the typed text on the first line of --print-query.
pick_profile() {
  local wanted="$1" table rows=() name key out rc query picked
  if [[ -n "$wanted" ]]; then
    validate_profile_name "$wanted" || return 1
    printf '%s\n' "$wanted"
    return 0
  fi

  if ! command -v fzf &>/dev/null; then
    echo "Error: fzf is required but not installed. Run: brew install fzf" >&2
    return 1
  fi

  table=$(aws_profile_keys)
  while IFS=$'\t' read -r name key; do
    [[ -n "$name" ]] && rows+=("$name"$'\t'"$(key_hint_for "$table" "$name")")
  done <<< "$table"

  out=$( { [[ ${#rows[@]} -gt 0 ]] && printf '%s\n' "${rows[@]}"; } |
    fzf --print-query --prompt="AWS CLI profile: " \
      --header="$PROFILE_HELP" --height=~15 --layout=reverse --border)
  rc=$?
  query=$(printf '%s\n' "$out" | sed -n 1p)
  picked=$(printf '%s\n' "$out" | sed -n 2p)

  if [[ $rc -eq 0 && -n "$picked" ]]; then
    print_choice "profile" "$picked"
    printf '%s\n' "${picked%%$'\t'*}"
    return 0
  fi
  # 1 is "no match", which is how a new name arrives; anything else (130) is a
  # cancelled menu.
  [[ $rc -eq 1 && -n "$query" ]] || return 1
  validate_profile_name "$query" || return 1
  print_choice "profile" "$query (new)"
  printf '%s\n' "$query"
}

PROFILE_HELP="An AWS CLI profile is a named set of keys saved in ~/.aws. Pick one, or type a new name and press Enter to create it."

# The region list behind the picker, fetched when it opens rather than kept
# here, so a region AWS opens appears without an ssm release. Public, and needs
# no AWS credentials -- an account being added may not have any yet. ssm.ps1
# uses the same URL, and test/parity_test.sh checks that. SSM_REGIONS_URL exists
# for test/commands_test.sh, which serves a fixture from a local server.
SSM_REGIONS_URL="${SSM_REGIONS_URL:-https://xcrone.github.io/aws-regions/data.json}"

# Prints "code<TAB>name" per region that is open and has a code yet; nothing
# at all when the list cannot be fetched.
fetch_regions() {
  curl -fsSL --max-time 5 "$SSM_REGIONS_URL" 2>/dev/null |
    jq -r '.regions[]? | select(.available == true and (.code // "") != "")
           | "\(.code)\t\(.name // "")"' 2>/dev/null
}

# Checked on shape, not against the fetched list, so a flag still works when
# the list cannot be reached. The prefix is two letters or more: the European
# Sovereign Cloud's is eusc-.
validate_region() {
  if [[ "$1" =~ ^[a-z]{2,}(-[a-z]+)+-[0-9]+$ ]]; then
    return 0
  fi
  echo "Error: '$1' is not an AWS region code, like ap-southeast-1." >&2
  echo "Leave out --region to pick one from a list." >&2
  return 1
}

# pick_region <wanted> [current]
pick_region() {
  local wanted="$1" current="$2" rows=() line picked header
  if [[ -n "$wanted" ]]; then
    validate_region "$wanted" || return 1
    printf '%s\n' "$wanted"
    return 0
  fi
  echo "Fetching AWS regions..." >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(fetch_regions)

  # Offline, or the list moved: asking for the code beats refusing to add.
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "Could not fetch the region list from $SSM_REGIONS_URL." >&2
    read -r -p "AWS region code (e.g. ap-southeast-1): " picked
    [[ -z "$picked" ]] && return 1
    validate_region "$picked" || return 1
    printf '%s\n' "$picked"
    return 0
  fi

  header="Type to filter by code or city, e.g. singapore."
  [[ -n "$current" ]] && header="Currently $current. $header"
  picked=$(select_menu_header "AWS region:" "$header" "${rows[@]}") || return 1
  [[ -z "$picked" ]] && return 1
  print_choice "region" "$picked"
  printf '%s\n' "${picked%%$'\t'*}"
}

# Asks for a new profile's keys and writes it. Nothing is written without both.
profile_create_prompt() {
  local profile="$1" region="$2" key secret
  echo "Creating AWS CLI profile '$profile'. Paste the access key pair from the AWS console (IAM > Security credentials)."
  key="$ARG_ACCESS_KEY"
  [[ -z "$key" ]] && read -r -p "Access Key ID: " key
  [[ -z "$key" ]] && { echo "Aborted: no access key given." >&2; return 1; }
  secret=$(read_secret_value "$ARG_SECRET_KEY") || return 1
  [[ -z "$secret" ]] && { echo "Aborted: no secret key given." >&2; return 1; }
  aws_profile_configure "$profile" "$key" "$secret" "$region"
  echo "AWS CLI profile '$profile' configured."
}

pick_app() {
  local wanted="$1" account="$2" profile="$3" region="$4"
  echo "Fetching apps..." >&2

  local apps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && apps+=("$line")
  done < <({ list_apps "$profile" "$region"; list_ecs_apps; } | sort -u | grep -v -e '^$' -e '^None$')

  if [[ ${#apps[@]} -eq 0 ]]; then
    echo "No running instances or ECS services with an App tag found." >&2
    return 1
  fi

  resolve_selection "$wanted" "app" "account $account" "Select application:" 1 "" "${apps[@]}"
}

pick_instance() {
  local wanted="$1" profile="$2" region="$3" app="$4"
  echo "Fetching instances for $app..." >&2

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_instances "$profile" "$region" "$app")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running instances found for app: $app" >&2
    return 1
  fi

  # Matched on the instance id or on its Name tag, whichever the user typed.
  local selected
  selected=$(resolve_selection "$wanted" "instance" "app $app" \
    "Select instance:" "1,2" auto "${rows[@]}") || return 1

  echo "$selected" | awk '{print $1}'
}

# The "Connect to:" menu, or the flags that stand in for it. --instance names an
# EC2 box, --container/--task name an ECS one, so either settles the question.
ssh_pick_target() {
  local target
  if [[ "$ARG_TYPE" == "ec2" || -n "$ARG_INSTANCE" ]]; then
    target="EC2 instance"
  elif [[ "$ARG_TYPE" == "ecs" || -n "$ARG_CONTAINER" || -n "$ARG_TASK" ]]; then
    target="ECS task"
  else
    target=$(select_menu "Connect to:" "EC2 instance" "ECS task") || return 1
  fi
  [[ -n "$target" ]] && print_choice "target" "$target"
  printf '%s' "$target"
}

# The "Open which shell?" menu on an ECS container instance, or its flags.
ssh_pick_shell() {
  local shell
  if [[ -n "$ARG_HOST" ]]; then
    shell="Host shell"
  elif [[ -n "$ARG_CONTAINER" || -n "$ARG_TASK" ]]; then
    shell="Container shell (ECS Exec)"
  else
    shell=$(select_menu "Open which shell?" "Host shell" "Container shell (ECS Exec)") || return 1
  fi
  [[ -n "$shell" ]] && print_choice "shell" "$shell"
  printf '%s' "$shell"
}

cmd_ssh() {
  parse_args "--env --app --type --instance --container --task" "--host" "$@" || exit 1

  case "$ARG_TYPE" in
    ""|ec2|ecs) ;;
    *) echo "Error: --type must be 'ec2' or 'ecs', not '$ARG_TYPE'." >&2; exit 1 ;;
  esac
  if [[ -n "$ARG_INSTANCE" && "$ARG_TYPE" == "ecs" ]]; then
    echo "Error: --instance names an EC2 instance and cannot be used with --type ecs." >&2
    exit 1
  fi
  if [[ -n "$ARG_HOST" && ( -n "$ARG_CONTAINER" || -n "$ARG_TASK" ) ]]; then
    echo "Error: --host opens the host shell and cannot be used with --container or --task." >&2
    exit 1
  fi

  local ACCOUNT PROFILE REGION APP INSTANCE_ID

  ACCOUNT=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$ACCOUNT" ]] && exit 0
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")

  # Runs in this shell, not a subshell, so pick_app below inherits ECS_SERVICES.
  discover_ecs_services "$PROFILE" "$REGION"

  APP=$(pick_app "$ARG_APP" "$ACCOUNT" "$PROFILE" "$REGION") || exit 1
  [[ -z "$APP" ]] && exit 0

  # If the app also has ECS services, offer the choice. An app backed only by
  # EC2 skips this entirely and follows the original flow.
  if [[ -n "$(ecs_services_for_app "$APP")" ]]; then
    local target="ECS task"
    if [[ -n "$(list_instances "$PROFILE" "$REGION" "$APP")" ]]; then
      target=$(ssh_pick_target)
      [[ -z "$target" ]] && exit 0
    fi
    if [[ "$target" == "ECS task" ]]; then
      ssh_ecs_app "$PROFILE" "$REGION" "$APP"
      return
    fi
  fi

  INSTANCE_ID=$(pick_instance "$ARG_INSTANCE" "$PROFILE" "$REGION" "$APP") || exit 1
  [[ -z "$INSTANCE_ID" ]] && exit 0

  # Autocheck: is this a plain EC2 box or an ECS container instance?
  local ecs_node cluster ci_arn shell_choice
  ecs_node=$(detect_ecs_container_instance "$PROFILE" "$REGION" "$INSTANCE_ID")
  if [[ -n "$ecs_node" ]]; then
    cluster=$(echo "$ecs_node" | awk -F'\t' '{print $1}')
    ci_arn=$(echo "$ecs_node" | awk -F'\t' '{print $2}')
    echo "" >&2
    echo "This instance is an ECS container instance in cluster $cluster." >&2
    shell_choice=$(ssh_pick_shell)
    [[ -z "$shell_choice" ]] && exit 0
    if [[ "$shell_choice" == "Container shell (ECS Exec)" ]]; then
      ssh_ecs_container_instance "$PROFILE" "$REGION" "$cluster" "$ci_arn"
      return
    fi

    # ECS container instances run the ECS-optimized AMI (Amazon Linux), which has
    # no `ubuntu` user, so pick the login user on the box instead of assuming it.
    echo "" >&2
    echo "Connecting to $INSTANCE_ID via SSM ..."
    aws ssm start-session \
      --profile "$PROFILE" \
      --region "$REGION" \
      --target "$INSTANCE_ID" \
      --document-name AWS-StartInteractiveCommand \
      --parameters '{"command": ["if id ubuntu >/dev/null 2>&1; then sudo su - ubuntu; else sudo su - ec2-user; fi"]}'
    return
  fi

  # A plain EC2 box runs no ECS tasks, so asking for a container here can only be
  # a mistake -- say so rather than silently dropping the user on the host.
  if [[ -n "$ARG_CONTAINER" || -n "$ARG_TASK" ]]; then
    echo "Error: $INSTANCE_ID is a plain EC2 instance, not an ECS container instance." >&2
    echo "There is no container to exec into. Drop --container/--task for a host shell." >&2
    exit 1
  fi

  echo "" >&2
  echo "Connecting to $INSTANCE_ID via SSM ..."
  aws ssm start-session \
    --profile "$PROFILE" \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartInteractiveCommand \
    --parameters '{"command": ["sudo su - ubuntu"]}'
}

# ---------------------------------------------------------------------------
# EKS support. Pods are not reachable over SSM at all -- they need kubectl --
# so this is a separate funnel behind `ssm pod`, not a branch of `ssm ssh`.
# ---------------------------------------------------------------------------

# Our own kubeconfig, so ~/.kube/config and your current context are never touched.
KUBECONFIG_FILE="$HOME/.ssm/kubeconfig"

require_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    echo "Error: kubectl is required for pod access but is not installed." >&2
    echo "Install it with: brew install kubernetes-cli" >&2
    exit 1
  fi
}

list_eks_clusters() {
  local profile="$1" region="$2"
  aws eks list-clusters \
    --profile "$profile" \
    --region "$region" \
    --query 'clusters[]' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v -e '^$' -e '^None$'
}

# Writes credentials for one cluster into our own kubeconfig and exports
# KUBECONFIG so every kubectl call below uses it.
use_eks_cluster() {
  local profile="$1" region="$2" cluster="$3"
  echo "Updating kubeconfig for $cluster..." >&2

  if ! aws eks update-kubeconfig \
    --profile "$profile" \
    --region "$region" \
    --name "$cluster" \
    --kubeconfig "$KUBECONFIG_FILE" >/dev/null 2>&1; then
    echo "Failed to fetch kubeconfig for $cluster." >&2
    echo "Check that your IAM principal is mapped in the cluster's aws-auth or access entries." >&2
    exit 1
  fi

  export KUBECONFIG="$KUBECONFIG_FILE"
}

list_namespaces() {
  kubectl get namespaces -o json 2>/dev/null \
    | jq -r '.items[].metadata.name'
}

# pod<TAB>ready<TAB>node
list_pods() {
  local namespace="$1"
  kubectl get pods -n "$namespace" -o json 2>/dev/null \
    | jq -r '
        .items[]
        | select(.status.phase == "Running")
        | [ .metadata.name,
            (([.status.containerStatuses[]? | select(.ready)] | length | tostring)
              + "/" + (.spec.containers | length | tostring)),
            (.spec.nodeName // "-") ]
        | @tsv'
}

list_pod_containers() {
  local namespace="$1" pod="$2"
  kubectl get pod "$pod" -n "$namespace" -o json 2>/dev/null \
    | jq -r '.spec.containers[].name'
}

kubectl_exec() {
  local namespace="$1" pod="$2" container="$3"

  echo "" >&2
  echo "Connecting to container $container in pod $pod ..."
  if ! kubectl exec -it -n "$namespace" "$pod" -c "$container" -- /bin/bash; then
    echo "" >&2
    echo "Retrying with /bin/sh ..." >&2
    kubectl exec -it -n "$namespace" "$pod" -c "$container" -- /bin/sh
  fi
}

pick_eks_cluster() {
  local wanted="$1" profile="$2" region="$3"
  echo "Fetching EKS clusters..." >&2

  local clusters=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && clusters+=("$line")
  done < <(list_eks_clusters "$profile" "$region")

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "No EKS clusters found in $region." >&2
    return 1
  fi

  resolve_selection "$wanted" "cluster" "region $region" \
    "Select cluster:" 1 auto "${clusters[@]}"
}

pick_namespace() {
  local wanted="$1"
  echo "Fetching namespaces..." >&2

  local namespaces=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && namespaces+=("$line")
  done < <(list_namespaces)

  if [[ ${#namespaces[@]} -eq 0 ]]; then
    echo "No namespaces found. Check your access to this cluster." >&2
    return 1
  fi

  resolve_selection "$wanted" "namespace" "this cluster" \
    "Select namespace:" 1 "" "${namespaces[@]}"
}

pick_pod() {
  local wanted="$1" namespace="$2"
  echo "Fetching pods in $namespace..." >&2

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_pods "$namespace")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running pods found in namespace: $namespace" >&2
    return 1
  fi

  local selected
  selected=$(resolve_selection "$wanted" "pod" "namespace $namespace" \
    "Select pod:" 1 auto "${rows[@]}") || return 1

  echo "$selected" | awk -F'\t' '{print $1}'
}

pick_pod_container() {
  local wanted="$1" namespace="$2" pod="$3"

  local containers=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && containers+=("$line")
  done < <(list_pod_containers "$namespace" "$pod")

  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "No containers found in pod: $pod" >&2
    return 1
  fi

  resolve_selection "$wanted" "container" "pod $pod" \
    "Select container:" 1 auto "${containers[@]}"
}

cmd_pod() {
  parse_args "--env --cluster --namespace --pod --container" "" "$@" || exit 1

  local ACCOUNT PROFILE REGION CLUSTER NAMESPACE POD CONTAINER

  require_kubectl

  ACCOUNT=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$ACCOUNT" ]] && exit 0
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")

  CLUSTER=$(pick_eks_cluster "$ARG_CLUSTER" "$PROFILE" "$REGION") || exit 1
  [[ -z "$CLUSTER" ]] && exit 0

  use_eks_cluster "$PROFILE" "$REGION" "$CLUSTER"

  NAMESPACE=$(pick_namespace "$ARG_NAMESPACE") || exit 1
  [[ -z "$NAMESPACE" ]] && exit 0

  POD=$(pick_pod "$ARG_POD" "$NAMESPACE") || exit 1
  [[ -z "$POD" ]] && exit 0

  CONTAINER=$(pick_pod_container "$ARG_CONTAINER" "$NAMESPACE" "$POD") || exit 1
  [[ -z "$CONTAINER" ]] && exit 0

  kubectl_exec "$NAMESPACE" "$POD" "$CONTAINER"
}

cmd_db() {
  parse_args "--env --app --db --instance" "" "$@" || exit 1

  local ACCOUNT PROFILE REGION APP
  local DB_IDENTIFIER RDS_HOST RDS_PORT LOCAL_PORT
  local INSTANCE_ID DB_ALIAS

  ACCOUNT=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$ACCOUNT" ]] && exit 0
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")
  APP=$(pick_app "$ARG_APP" "$ACCOUNT" "$PROFILE" "$REGION") || exit 1
  [[ -z "$APP" ]] && exit 0

  echo "Fetching RDS instances for $APP..." >&2
  local rds_rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rds_rows+=("$line")
  done < <(list_rds_instances "$PROFILE" "$REGION" "$APP")

  if [[ ${#rds_rows[@]} -eq 0 ]]; then
    echo "No RDS instances found for app: $APP" >&2
    exit 1
  fi

  local selected_rds
  selected_rds=$(resolve_selection "$ARG_DB" "database" "app $APP" \
    "Select database:" 1 auto "${rds_rows[@]}") || exit 1
  [[ -z "$selected_rds" ]] && exit 0

  DB_IDENTIFIER=$(echo "$selected_rds" | awk '{print $1}')
  RDS_HOST=$(echo "$selected_rds" | awk '{print $2}')
  RDS_PORT=$(echo "$selected_rds" | awk '{print $3}')
  LOCAL_PORT=$(get_db_port "$ACCOUNT" "$DB_IDENTIFIER")

  echo "Fetching jump-host for $APP..." >&2
  if [[ -n "$ARG_INSTANCE" ]]; then
    INSTANCE_ID=$(pick_instance "$ARG_INSTANCE" "$PROFILE" "$REGION" "$APP") || exit 1
  else
    INSTANCE_ID=$(list_instances "$PROFILE" "$REGION" "$APP" | awk 'NR==1{print $1}')
  fi
  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "No running EC2 instances found for app: $APP" >&2
    exit 1
  fi

  DB_ALIAS="${DB_IDENTIFIER}.tunnel"
  tunnel_acquire "$DB_ALIAS"

  # The alias is baked into the trap text now, not read when the trap fires:
  # an EXIT trap runs after cmd_db has returned, when its locals are gone. It
  # used to read $DB_ALIAS then, got "", and deleted every 127.0.0.1 line.
  # shellcheck disable=SC2064
  trap "echo ''; tunnel_release '$DB_ALIAS'" EXIT

  local params
  params=$(jq -n \
    --arg host "$RDS_HOST" \
    --arg port "$RDS_PORT" \
    --arg local "$LOCAL_PORT" \
    '{"host":[$host],"portNumber":[$port],"localPortNumber":[$local]}')

  echo ""
  print_tunnel_banner "$DB_ALIAS" "$LOCAL_PORT" "$RDS_HOST" "$RDS_PORT"
  echo ""
  echo "Opening tunnel via $INSTANCE_ID ..."
  aws ssm start-session \
    --profile "$PROFILE" \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "$params"
}

cmd_config() {
  # The action is a verb, so it reads as a subcommand rather than a flag value.
  local action=""
  case "$1" in
    view|add|edit|delete) action="$1"; shift ;;
    ""|-*) ;;
    *)
      echo "Error: unknown config action '$1'." >&2
      echo "" >&2
      usage_for config >&2
      exit 1
      ;;
  esac

  parse_args "--env --name --profile --region --access-key --secret-key --db --port" \
    "--skip-credentials --yes --delete-profile --force" "$@" || exit 1

  if [[ -z "$action" ]]; then
    action=$(select_menu "Config action:" "view" "add" "edit" "delete")
    [[ -z "$action" ]] && exit 0
  fi

  case "$action" in
    view)   config_view ;;
    add)    config_add ;;
    edit)   config_edit ;;
    delete) config_delete ;;
  esac
}

# Writes one field of one account. The read-modify-write shape is the same
# everywhere in this script: build the new document, then replace the file.
config_set_field() {
  local account="$1" field="$2" value="$3" updated
  updated=$(jq ".[\"$account\"][\"$field\"] = \"$value\"" "$CONFIG_FILE") || return 1
  echo "$updated" > "$CONFIG_FILE"
  echo "Updated $account.$field -> '$value'."
}

# Ports land in the config as JSON numbers, so a value that is not all digits
# has to be caught before it reaches jq.
validate_port() {
  local port="$1"
  case "$port" in
    '' | *[!0-9]*)
      echo "Error: port must be a whole number in 1-65535, got '$port'." >&2
      return 1
      ;;
  esac
  if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    echo "Error: port must be a whole number in 1-65535, got '$port'." >&2
    return 1
  fi
}

config_account_exists() {
  jq -e --arg name "$1" 'has($name)' "$CONFIG_FILE" >/dev/null 2>&1
}

# Moves the whole account object, so the profile, region and db port map all
# follow the new name. The AWS CLI profile is a field, not the key, so renaming
# an account never touches ~/.aws.
config_rename_account() {
  local old="$1" new="$2" updated
  if config_account_exists "$new"; then
    echo "Error: account '$new' already exists in $CONFIG_FILE." >&2
    return 1
  fi
  updated=$(jq --arg old "$old" --arg new "$new" \
    '.[$new] = .[$old] | del(.[$old])' "$CONFIG_FILE") || return 1
  echo "$updated" > "$CONFIG_FILE"
  echo "Renamed account '$old' -> '$new'."
}

config_set_db_port() {
  local account="$1" db="$2" port="$3" updated clash
  validate_port "$port" || return 1
  # --argjson wants a canonical decimal; "015432" is not valid JSON on its own.
  port=$((10#$port))

  # get_db_port avoids collisions when it picks a port for you; a port you name
  # yourself is your call, so this warns and still writes it.
  clash=$(jq -r --arg acct "$account" --arg db "$db" --argjson port "$port" '
    [ to_entries[]
      | .key as $a
      | (.value.databases // {}) | to_entries[]
      | select(.value == $port and ($a != $acct or .key != $db))
      | "\($a).\(.key)" ] | join(", ")' "$CONFIG_FILE")
  [[ -n "$clash" ]] && echo "Warning: port $port is already assigned to $clash." >&2

  updated=$(jq --arg acct "$account" --arg db "$db" --argjson port "$port" \
    '.[$acct].databases = ((.[$acct].databases // {}) | .[$db] = $port)' \
    "$CONFIG_FILE") || return 1
  echo "$updated" > "$CONFIG_FILE"
  echo "Set $account.$db port -> $port."
}

config_unset_db_port() {
  local account="$1" db="$2" updated existing
  existing=$(jq -r --arg acct "$account" --arg db "$db" \
    '.[$acct].databases[$db] // empty' "$CONFIG_FILE")
  if [[ -z "$existing" ]]; then
    echo "Error: no port assignment for '$db' in account '$account'." >&2
    return 1
  fi
  updated=$(jq --arg acct "$account" --arg db "$db" \
    'del(.[$acct].databases[$db])' "$CONFIG_FILE") || return 1
  echo "$updated" > "$CONFIG_FILE"
  echo "Removed port $existing for '$db' in account '$account'."
}

aws_profile_configure() {
  local profile="$1" key="$2" secret="$3" region="$4"
  aws configure set aws_access_key_id     "$key"    --profile "$profile"
  aws configure set aws_secret_access_key "$secret" --profile "$profile"
  aws configure set region                "$region" --profile "$profile"
  aws configure set output                "json"    --profile "$profile"
}

config_view() {
  if [[ -n "$ARG_ENV" ]]; then
    pick_account "$ARG_ENV" >/dev/null || exit 1
    jq ".[\"$ARG_ENV\"]" "$CONFIG_FILE"
  else
    jq '.' "$CONFIG_FILE"
  fi

  echo ""
  echo "AWS CLI profiles:"
  while IFS= read -r account; do
    local profile key masked cli_region
    profile=$(load_config "$account" "profile")
    key=$(aws configure get aws_access_key_id --profile "$profile" 2>/dev/null)
    cli_region=$(aws configure get region --profile "$profile" 2>/dev/null)
    if [[ -n "$key" ]]; then
      masked="${key:0:4}****${key: -4}"
    else
      masked="(not set)"
    fi
    printf "  %-20s profile=%-20s key=%-16s region=%s\n" \
      "$account" "$profile" "$masked" "${cli_region:-(not set)}"
  done < <(if [[ -n "$ARG_ENV" ]]; then echo "$ARG_ENV"; else list_accounts; fi)
}

config_add() {
  local name profile region
  name="$ARG_ENV"
  [[ -z "$name" ]] && read -r -p "Account name (your label for this AWS account in ssm, e.g. staging): " name
  [[ -z "$name" ]] && { echo "Aborted." >&2; return 1; }

  # Adding over an existing account used to replace it silently, taking its db
  # port assignments with it. --force keeps that behaviour, deliberately.
  if config_account_exists "$name"; then
    if [[ -z "$ARG_FORCE" ]]; then
      echo "Error: account '$name' already exists in $CONFIG_FILE." >&2
      echo "Use 'ssm config edit --env $name' to change it, or --force to replace it." >&2
      return 1
    fi
    echo "Replacing existing account '$name'."
  fi

  profile=$(pick_profile "$ARG_PROFILE") || { echo "Aborted." >&2; return 1; }
  region=$(pick_region "$ARG_REGION") || { echo "Aborted." >&2; return 1; }

  # The AWS CLI profile is settled before the account is written, so backing
  # out of the key prompts leaves nothing half-added.
  local creds_given=""
  [[ -n "$ARG_ACCESS_KEY" || -n "$ARG_SECRET_KEY" || -n "$SSM_AWS_SECRET_KEY" ]] && creds_given=1

  if [[ -n "$ARG_SKIP_CREDENTIALS" ]]; then
    if ! aws_profile_exists "$profile"; then
      echo "Warning: AWS CLI profile '$profile' does not exist yet; ssm cannot reach AWS until it is set up." >&2
    fi
  elif aws_profile_exists "$profile" && [[ -z "$creds_given" ]]; then
    echo "Using existing AWS CLI profile '$profile' $(key_hint_for "$(aws_profile_keys)" "$profile")."
  else
    profile_create_prompt "$profile" "$region" || return 1
  fi

  local updated
  updated=$(jq --arg name "$name" --arg profile "$profile" --arg region "$region" \
    '.[$name] = {"profile": $profile, "region": $region, "databases": {}}' "$CONFIG_FILE") || return 1
  echo "$updated" > "$CONFIG_FILE"
  echo "Account '$name' added."
}

config_delete() {
  local account updated
  account=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$account" ]] && exit 0

  # --db narrows the delete to a single port assignment; without it the whole
  # account goes, as before.
  if [[ -n "$ARG_DB" ]]; then
    if [[ -z "$ARG_YES" ]]; then
      local confirm_db
      read -r -p "Delete port assignment '$ARG_DB' from account '$account'? [y/N]: " confirm_db
      [[ "$confirm_db" != "y" && "$confirm_db" != "Y" ]] && { echo "Aborted." >&2; return; }
    fi
    config_unset_db_port "$account" "$ARG_DB"
    return $?
  fi

  # Deleting is the one destructive action here, so it still asks unless --yes.
  if [[ -z "$ARG_YES" ]]; then
    local confirm
    read -r -p "Delete account '$account'? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted." >&2; return; }
  fi

  local profile
  profile=$(load_config "$account" "profile")

  updated=$(jq "del(.[\"$account\"])" "$CONFIG_FILE")
  echo "$updated" > "$CONFIG_FILE"
  echo "Account '$account' deleted."

  local del_profile="$ARG_DELETE_PROFILE"
  if [[ -z "$del_profile" && -z "$ARG_YES" ]]; then
    local answer
    read -r -p "Also delete AWS CLI profile '$profile'? [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] && del_profile=1
  fi
  if [[ -n "$del_profile" ]]; then
    python3 - "$profile" <<'EOF'
import configparser, os, sys
profile = sys.argv[1]

for path, section in [
  (os.path.expanduser("~/.aws/credentials"), profile),
  (os.path.expanduser("~/.aws/config"),      f"profile {profile}"),
]:
  if not os.path.exists(path):
    continue
  c = configparser.ConfigParser()
  c.read(path)
  if c.remove_section(section):
    with open(path, "w") as f:
      c.write(f)
EOF
    echo "AWS CLI profile '$profile' removed."
  fi
}

config_edit() {
  local account field profile

  account=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$account" ]] && exit 0

  profile=$(load_config "$account" "profile")

  # Field flags apply every field they name in one pass, so --profile and
  # --region together take one command instead of two trips through the menu.
  if [[ -n "$ARG_NAME" || -n "$ARG_PROFILE" || -n "$ARG_REGION" || -n "$ARG_ACCESS_KEY" \
     || -n "$ARG_SECRET_KEY" || -n "$SSM_AWS_SECRET_KEY" || -n "$ARG_DB" || -n "$ARG_PORT" ]]; then
    # Rename first so every other edit in this pass lands on the new name.
    if [[ -n "$ARG_NAME" ]]; then
      config_rename_account "$account" "$ARG_NAME" || return 1
      account="$ARG_NAME"
    fi
    # Both are checked before anything is written, so a bad value changes nothing.
    if [[ -n "$ARG_PROFILE" ]]; then validate_profile_name "$ARG_PROFILE" || return 1; fi
    if [[ -n "$ARG_REGION" ]]; then validate_region "$ARG_REGION" || return 1; fi
    if [[ -n "$ARG_PROFILE" ]]; then
      config_set_field "$account" "profile" "$ARG_PROFILE" || return 1
      # Credential edits below belong to the profile we just moved to.
      profile="$ARG_PROFILE"
    fi
    [[ -n "$ARG_REGION" ]] && { config_set_field "$account" "region" "$ARG_REGION" || return 1; }
    if [[ -n "$ARG_ACCESS_KEY" ]]; then
      aws configure set aws_access_key_id "$ARG_ACCESS_KEY" --profile "$profile"
      echo "Updated AWS access key for profile '$profile'."
    fi
    if [[ -n "$ARG_SECRET_KEY" || -n "$SSM_AWS_SECRET_KEY" ]]; then
      local secret
      secret=$(read_secret_value "$ARG_SECRET_KEY") || return 1
      [[ -z "$secret" ]] && { echo "Aborted." >&2; return 1; }
      aws configure set aws_secret_access_key "$secret" --profile "$profile"
      echo "Updated AWS secret key for profile '$profile'."
    fi
    if [[ -n "$ARG_DB" || -n "$ARG_PORT" ]]; then
      if [[ -z "$ARG_DB" || -z "$ARG_PORT" ]]; then
        echo "Error: --db and --port go together -- --db names the database, --port its local port." >&2
        return 1
      fi
      config_set_db_port "$account" "$ARG_DB" "$ARG_PORT" || return 1
    fi
    return 0
  fi

  field=$(select_menu "Select field to edit:" \
    "name" "profile" "region" "aws-access-key" "aws-secret-key" "database-port")
  [[ -z "$field" ]] && exit 0

  case "$field" in
    name)
      local value
      read -r -p "New account name [$account]: " value
      [[ -z "$value" || "$value" == "$account" ]] && { echo "Unchanged."; return 0; }
      config_rename_account "$account" "$value"
      ;;
    database-port)
      local dbs=() db current value
      while IFS= read -r line; do
        [[ -n "$line" ]] && dbs+=("$line")
      done < <(jq -r --arg acct "$account" '(.[$acct].databases // {}) | keys[]' "$CONFIG_FILE")
      if [[ ${#dbs[@]} -eq 0 ]]; then
        echo "No port assignments for '$account' yet. 'ssm db' creates one on first use." >&2
        return 1
      fi
      db=$(select_menu "Select database:" "${dbs[@]}") || return 1
      [[ -z "$db" ]] && return 0
      current=$(jq -r --arg acct "$account" --arg db "$db" \
        '.[$acct].databases[$db]' "$CONFIG_FILE")
      read -r -p "Local port for $db [$current] (or 'none' to remove): " value
      value="${value:-$current}"
      if [[ "$value" == "none" ]]; then
        config_unset_db_port "$account" "$db"
      else
        config_set_db_port "$account" "$db" "$value"
      fi
      ;;
    profile)
      local value
      value=$(pick_profile "") || return 1
      if ! aws_profile_exists "$value"; then
        profile_create_prompt "$value" "$(load_config "$account" "region")" || return 1
      fi
      config_set_field "$account" "profile" "$value"
      ;;
    region)
      local value
      value=$(pick_region "" "$(load_config "$account" "region")") || return 1
      config_set_field "$account" "region" "$value"
      ;;
    aws-access-key)
      local current value
      current=$(aws configure get aws_access_key_id --profile "$profile" 2>/dev/null)
      read -r -p "Access Key ID [${current:-not set}]: " value
      value="${value:-$current}"
      aws configure set aws_access_key_id "$value" --profile "$profile"
      echo "Updated AWS access key for profile '$profile'."
      ;;
    aws-secret-key)
      local value
      value=$(read_secret_value "") || return 1
      [[ -z "$value" ]] && { echo "Aborted." >&2; return; }
      aws configure set aws_secret_access_key "$value" --profile "$profile"
      echo "Updated AWS secret key for profile '$profile'."
      ;;
  esac
}

# Downloads to a temp file and renames it into place. The rename matters: bash
# reads a script lazily, seeking back to its last offset after every command, so
# truncating this file while it is running makes bash resume inside the *new*
# bytes and die on a bogus syntax error. A rename gives the new script a new
# inode and leaves the running one readable until it exits.
cmd_update() {
  parse_args "" "" "$@" || exit 1

  local SSM_SCRIPT="$HOME/.ssm/ssm.sh"
  local CDN_URL="https://cdn.supplycart.my/shells/aws-ssm-manager/ssm.sh"
  local tmp="$SSM_SCRIPT.new.$$"

  trap 'rm -f "$tmp"' EXIT

  echo "Downloading latest ssm.sh from CDN..."
  if ! curl -fsSL "$CDN_URL" -o "$tmp"; then
    echo "Update failed. Could not download from $CDN_URL" >&2
    exit 1
  fi

  # A truncated download would otherwise replace a working ssm with one that
  # cannot even run 'ssm update' again. bash 3.2 does not flag an unterminated
  # heredoc, so check the shebang too -- between them they catch a short read.
  if [ "$(head -c 2 "$tmp")" != "#!" ] || ! bash -n "$tmp" 2>/dev/null; then
    echo "Update failed. The download from $CDN_URL is not a valid script." >&2
    exit 1
  fi

  local new_version
  new_version=$(script_version "$tmp")

  chmod +x "$tmp"
  mv "$tmp" "$SSM_SCRIPT"
  if [[ "$new_version" == "$SSM_VERSION" ]]; then
    echo "ssm is already at $SSM_VERSION."
  else
    echo "ssm updated: $SSM_VERSION -> $new_version"
  fi
}

# Prints the version a script file was stamped with, or "unknown" for a copy
# released before ssm had versions.
script_version() {
  local version
  version=$(sed -n 's/^SSM_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | sed -n 1p)
  echo "${version:-unknown}"
}

cmd_version() {
  parse_args "" "" "$@" || exit 1
  echo "ssm $SSM_VERSION"
}

# ---------------------------------------------------------------------------
# Uninstall. Paths are where install.sh puts things; they are globals so the
# test suite can point them at a scratch directory.
# ---------------------------------------------------------------------------
SSM_DIR="$HOME/.ssm"
SSM_SCRIPT="$SSM_DIR/ssm.sh"
UNINSTALL_BIN_DIR="/usr/local/bin"
SSM_SYMLINK="$UNINSTALL_BIN_DIR/ssm"
AWS_CLI_DIR="/usr/local/aws-cli"
SSM_PLUGIN_DIR="/usr/local/sessionmanagerplugin"
UNINSTALL_BREW_PACKAGES="fzf jq kubernetes-cli"

tilde_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *)         printf '%s' "$1" ;;
  esac
}

# True when <link> is a symlink to <target> or to something inside it.
uninstall_link_into() {
  [[ -L "$1" ]] || return 1
  local dest
  dest=$(readlink "$1")
  [[ "$dest" == "$2" || "$dest" == "$2"/* ]]
}

# Removes paths as the user, falling back to sudo for what the pkg installers
# and install.sh's symlink left root-owned.
uninstall_rm() {
  rm -rf -- "$@" 2>/dev/null && return 0
  sudo rm -rf -- "$@"
}

# The checklist rows: "key<TAB>label" for each optional item actually present,
# in the order install.sh adds them.
uninstall_optional_rows() {
  local pkg label
  if [[ -n "$(find "$SSM_DIR" -mindepth 1 -maxdepth 1 ! -name ssm.sh 2>/dev/null | head -1)" ]]; then
    printf 'config\t%-24s %s\n' "$(tilde_path "$SSM_DIR")" "config.json, db ports, kubeconfig"
  fi
  if command -v brew &>/dev/null; then
    for pkg in $UNINSTALL_BREW_PACKAGES; do
      brew list --formula "$pkg" &>/dev/null || continue
      label="$pkg"
      [[ "$pkg" == "kubernetes-cli" ]] && label="kubectl"
      printf '%s\t%-24s brew uninstall %s\n' "$pkg" "$label" "$pkg"
    done
  fi
  [[ -d "$AWS_CLI_DIR" ]] && printf 'aws-cli\t%-24s %s (sudo)\n' "AWS CLI v2" "$AWS_CLI_DIR"
  [[ -d "$SSM_PLUGIN_DIR" ]] &&
    printf 'session-manager-plugin\t%-24s %s (sudo)\n' "session-manager-plugin" "$SSM_PLUGIN_DIR"
  return 0
}

# The checklist answer the flags stand for, when the checklist is not opened.
uninstall_flagged_keys() {
  local row key
  for row in "$@"; do
    key="${row%%$'\t'*}"
    if [[ "$key" == "config" ]]; then
      [[ -n "$ARG_PURGE" ]] && echo "$key"
    else
      [[ -n "$ARG_WITH_DEPS" ]] && echo "$key"
    fi
  done
  return 0
}

# The part of an uninstall that always happens: the command and its script. A
# symlink pointing anywhere else belongs to some other ssm and is left alone.
#
# Deleting the running script is safe, unlike overwriting it (see cmd_update):
# rm only unlinks the name, and bash keeps reading the open file until it exits.
uninstall_core() {
  local status=0
  if uninstall_link_into "$SSM_SYMLINK" "$SSM_SCRIPT"; then
    if uninstall_rm "$SSM_SYMLINK"; then echo "Removed $SSM_SYMLINK"; else status=1; fi
  elif [[ -e "$SSM_SYMLINK" || -L "$SSM_SYMLINK" ]]; then
    echo "Left $SSM_SYMLINK alone: it does not point at $(tilde_path "$SSM_SCRIPT")." >&2
  fi
  if [[ -e "$SSM_SCRIPT" ]]; then
    if rm -f "$SSM_SCRIPT"; then echo "Removed $(tilde_path "$SSM_SCRIPT")"; else status=1; fi
  fi
  # Only succeeds when nothing the user might want back is still in there.
  rmdir "$SSM_DIR" 2>/dev/null
  return $status
}

# Undoes an AWS pkg install the way AWS documents it: the install directory and
# its links in /usr/local/bin. A link into some other install -- a brew awscli,
# say -- is not ours and stays.
uninstall_remove_pkg() {
  local label="$1" dir="$2" name
  shift 2
  for name in "$@"; do
    if uninstall_link_into "$UNINSTALL_BIN_DIR/$name" "$dir"; then
      uninstall_rm "$UNINSTALL_BIN_DIR/$name" || return 1
    fi
  done
  uninstall_rm "$dir" || return 1
  echo "Removed $label ($dir)"
}

uninstall_remove() {
  case "$1" in
    config)
      uninstall_rm "${SSM_DIR:?}" || return 1
      echo "Removed $(tilde_path "$SSM_DIR")"
      ;;
    aws-cli)
      uninstall_remove_pkg "AWS CLI v2" "$AWS_CLI_DIR" aws aws_completer
      ;;
    session-manager-plugin)
      uninstall_remove_pkg "session-manager-plugin" "$SSM_PLUGIN_DIR" session-manager-plugin
      ;;
    *)
      if [[ " $UNINSTALL_BREW_PACKAGES " != *" $1 "* ]]; then
        echo "Unknown item '$1'." >&2
        return 1
      fi
      brew uninstall "$1"
      ;;
  esac
}

cmd_uninstall() {
  parse_args "" "--yes --purge --with-deps" "$@" || exit 1

  local rows=() row
  while IFS= read -r row; do
    rows+=("$row")
  done < <(uninstall_optional_rows)

  echo "ssm uninstall removes:"
  echo "  $SSM_SYMLINK"
  echo "  $(tilde_path "$SSM_SCRIPT")"
  echo "It never touches ~/.aws or Homebrew itself."
  echo ""

  if [[ -z "$ARG_YES" ]]; then
    local confirm
    read -r -p "Uninstall ssm? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted." >&2; return; }
  fi

  local selected=""
  if [[ -n "$ARG_YES$ARG_PURGE$ARG_WITH_DEPS" ]]; then
    selected=$(uninstall_flagged_keys "${rows[@]}")
  elif [[ ${#rows[@]} -gt 0 ]]; then
    selected=$(select_multi "Also remove?" \
      "Tab marks, Enter confirms. Other tools on this Mac may rely on these." "${rows[@]}") \
      || { echo "Aborted." >&2; return; }
  fi

  local failed=0 key
  uninstall_core || failed=1
  for key in $selected; do
    uninstall_remove "$key" || failed=1
  done

  echo ""
  if [[ $failed -ne 0 ]]; then
    echo "Some items could not be removed -- see the errors above." >&2
    exit 1
  fi
  echo "ssm uninstalled."
  if [[ -d "$SSM_DIR" ]]; then
    echo "Kept $(tilde_path "$SSM_DIR"); a reinstall picks it up. Delete it by hand once you are done with it."
  fi
}

# Per-command usage. `ssm help` prints all of it; `ssm <cmd> --help` prints one
# block. Kept in one function so the two can never drift apart.
usage_for() {
  case "$1" in
    ssh)
      cat <<'EOF'
ssm ssh — Shell into an EC2 instance, an ECS container instance, or an
          ECS/Fargate container.

  ssm ssh [--env <name>] [--app <name>] [--type ec2|ecs]
          [--instance <id|Name>] [--container <name>] [--task <id>] [--host]

  --env, -e     account in ~/.ssm/config.json    (default: pick from a menu)
  --app         App tag                          (default: pick from a menu)
  --type        ec2 or ecs, when the app has both
  --instance    EC2 instance id or Name tag; implies --type ec2
  --container   container name; implies --type ecs, or the container shell
                on an ECS container instance
  --task        ECS task id, to disambiguate when --container matches several
  --host        on an ECS container instance, open the host shell

EXAMPLES
  ssm ssh                                       fully interactive
  ssm ssh --env staging                         skips the account menu
  ssm ssh --env staging --app adam              no prompts if the app has one instance
  ssm ssh --env staging --instance web-01       match an EC2 Name tag
  ssm ssh --env staging --instance i-0abc123    or an instance id
  ssm ssh --env staging --app adam --container php-fpm
  ssm ssh --env staging --app adam --container php-fpm --task 7d9f2a
  ssm ssh --env staging --app adam --type ecs   when the app has both EC2 and ECS
  ssm ssh --env staging --app adam --host       host shell on an ECS node
EOF
      ;;
    pod)
      cat <<'EOF'
ssm pod — Shell into an EKS pod via kubectl.

  ssm pod [--env <name>] [--cluster <name>] [--namespace|-n <ns>]
          [--pod <name>] [--container|-c <name>]

  --env, -e       account in ~/.ssm/config.json  (default: pick from a menu)
  --cluster       EKS cluster name
  --namespace, -n Kubernetes namespace
  --pod           pod name (running pods only)
  --container, -c container name within the pod

EXAMPLES
  ssm pod                                       fully interactive
  ssm pod --env staging                         skips the account menu
  ssm pod --env staging --cluster sc-staging-eks
  ssm pod --env staging -n default              skips the namespace menu
  ssm pod --env staging -n default --pod api-7d9f
  ssm pod --env staging -n default --pod api-7d9f -c sidecar
EOF
      ;;
    db)
      cat <<'EOF'
ssm db — Open an RDS tunnel via SSM port forwarding.

  ssm db [--env <name>] [--app <name>] [--db <identifier>] [--instance <id|Name>]

  --env, -e     account in ~/.ssm/config.json    (default: pick from a menu)
  --app         App tag                          (default: pick from a menu)
  --db          RDS DBInstanceIdentifier
  --instance    EC2 instance to tunnel through   (default: the first one found)

The local port is assigned on first use and remembered in ~/.ssm/config.json.
Change it with `ssm config edit --env <name> --db <id> --port <n>`.

EXAMPLES
  ssm db                                        fully interactive
  ssm db --env staging                          skips the account menu
  ssm db --env staging --app adam               no prompts if the app has one database
  ssm db --env staging --app adam --db sc-staging-adam-rds
  ssm db --env staging --app adam --db sc-staging-adam-rds --instance web-01
EOF
      ;;
    config)
      cat <<'EOF'
ssm config — Manage account profiles and AWS CLI credentials.

  ssm config [view|add|edit|delete] [flags]      (no action: pick from a menu)

  ssm config view   [--env <name>]
  ssm config add    --env <name> [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -] [--skip-credentials]
                    [--force]
  ssm config edit   --env <name> [--name <new>] [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -]
                    [--db <id> --port <n>]
  ssm config delete --env <name> [--yes] [--delete-profile]
  ssm config delete --env <name> --db <id> [--yes]

  --name            rename the account; keeps its region and db ports, and does
                    not touch the AWS CLI profile
  --db, --port      set the local tunnel port for one database (both required)
  --force           let `add` replace an account that already exists
  --yes             skip the delete confirmation
  --delete-profile  also remove the profile from ~/.aws/credentials and config

EXAMPLES
  ssm config                                    pick an action from a menu
  ssm config view                               every account
  ssm config view --env staging                 one account
  ssm config add --env staging --profile sc-staging --region ap-southeast-5
  ssm config add --env staging --profile sc-staging --region ap-southeast-5 \
    --skip-credentials                          config only, no AWS CLI setup
  SSM_AWS_SECRET_KEY=... ssm config add --env staging --profile sc-staging \
    --region ap-southeast-5 --access-key AKIA...
  ssm config edit --env staging --region ap-southeast-1
  ssm config edit --env staging --name stg      rename the account
  ssm config edit --env staging --db sc-staging-adam-rds --port 15433
  ssm config delete --env staging --db sc-staging-adam-rds --yes
  ssm config delete --env staging --yes --delete-profile

Never pass a secret as a flag value -- it lands in your shell history. Set
SSM_AWS_SECRET_KEY=... or use '--secret-key -' to read one line from stdin.
EOF
      ;;
    version)
      cat <<'EOF'
ssm version — Print the installed ssm version.

  ssm version

A released copy prints its tag, e.g. v1.2.3. A copy run straight from a git
checkout prints "dev".
EOF
      ;;
    uninstall)
      cat <<'EOF'
ssm uninstall — Remove ssm, and optionally its config and dependencies.

  ssm uninstall [--yes] [--purge] [--with-deps]

Always removes /usr/local/bin/ssm and ~/.ssm/ssm.sh, then opens a checklist of
what else is present: ~/.ssm (config, db ports, kubeconfig) and the dependencies
install.sh adds -- fzf, jq, kubectl, AWS CLI v2 and the Session Manager plugin.
Nothing on the checklist is removed unless you mark it; other tools may rely on
those dependencies. ~/.aws and Homebrew are never touched.

  --yes         skip the confirmation; remove only what the other flags name
  --purge       also delete ~/.ssm
  --with-deps   also remove every installed dependency listed above

Passing --purge or --with-deps answers the checklist instead of opening it.

EXAMPLES
  ssm uninstall                                 confirm, then pick from a checklist
  ssm uninstall --yes                           the command only; keep config and deps
  ssm uninstall --yes --purge                   the command and ~/.ssm
  ssm uninstall --yes --purge --with-deps       everything install.sh added
EOF
      ;;
    *)
      cmd_help
      ;;
  esac
}

# `ssm` with no command asks what to do, rather than printing a usage block at
# someone who just wants to connect to something. This is the entry point the
# Windows Start Menu shortcut launches, and it is worth having on macOS too.
#
# It prints the chosen command for the dispatch block to run; printing nothing
# means the menu was cancelled. Only the command name is echoed, so the caller
# can use it directly -- everything else the menu draws is fzf's own, on the
# terminal rather than on stdout.
cmd_menu() {
  # The labels are the ones from cmd_help, shortened to one line each.
  local items=(
    "ssh        Shell into an EC2 instance or an ECS container"
    "pod        Shell into an EKS pod"
    "db         Open an RDS tunnel"
    "config     View, add, edit, or delete AWS account profiles"
    "update     Replace this script with the latest version"
    "uninstall  Remove ssm, and optionally its config and dependencies"
    "version    Print the installed version"
    "help       Show the full flag reference"
  )

  local choice
  choice=$(select_menu "What do you want to do?" "${items[@]}") || return 1
  [[ -z "$choice" ]] && return 1

  # The key is the first word of the row.
  printf '%s\n' "${choice%% *}"
}

cmd_help() {
  cat <<'EOF'

USAGE
  ssm <command> [flags]      every flag you omit falls back to its menu

  ssm ssh        Shell into an EC2 instance, an ECS container instance, or an
                 ECS/Fargate container. Detects ECS nodes and asks whether you
                 want the host shell or a container shell.
  ssm pod        Shell into an EKS pod via kubectl (cluster -> namespace -> pod)
  ssm db         Open an RDS tunnel via SSM port forwarding
  ssm config     View, add, edit, or delete AWS account profiles
  ssm update     Replace this script with the latest version from CDN
  ssm uninstall  Remove ssm, and optionally its config and dependencies
  ssm version    Print the installed version
  ssm help       Show this text

  Run `ssm <command> --help` for that command's flags.

FLAGS
  ssm ssh        [--env <name>] [--app <name>] [--type ec2|ecs]
                 [--instance <id|Name>] [--container <name>] [--task <id>]
                 [--host]
  ssm pod        [--env <name>] [--cluster <name>] [-n <namespace>]
                 [--pod <name>] [-c <container>]
  ssm db         [--env <name>] [--app <name>] [--db <identifier>]
                 [--instance <id|Name>]
  ssm config     [view|add|edit|delete] [--env <name>] [--name <new>]
                 [--profile <p>] [--region <r>] [--db <id> --port <n>]
                 [--access-key <k>] [--secret-key -] [--skip-credentials]
                 [--force] [--yes] [--delete-profile]
  ssm uninstall  [--yes] [--purge] [--with-deps]

EXAMPLES
  ssm ssh                                     fully interactive, as before
  ssm ssh --env staging                       skips the account menu
  ssm ssh --env staging --app adam            no prompts if the app has one instance
  ssm ssh --env staging --app adam --container php-fpm
  ssm ssh --env staging --instance web-01     match an EC2 Name tag or id
  ssm db  --env staging --app adam --db sc-staging-adam-rds
  ssm pod --env staging -n default --pod api-7d9f
  ssm config view --env staging
  ssm config add --env staging --profile sc-staging --region ap-southeast-5
  ssm config edit --env staging --name stg --region ap-southeast-1
  ssm config edit --env staging --db sc-staging-adam-rds --port 15433
  ssm config delete --env staging --yes --delete-profile

  A value that does not exist is an error listing the valid ones, so a fully
  flagged command never stops to ask a question.

  Run `ssm <command> --help` for that command's full flag list and examples.

SECRETS
  Never pass a secret key as a flag value -- it is recorded in your shell
  history. Use SSM_AWS_SECRET_KEY=... or '--secret-key -' to read one line
  from stdin.

CONFIG FILE
  ~/.ssm/config.json — maps account names to AWS CLI profiles and regions.
  DB port assignments are auto-saved here on first use.
  ~/.ssm/kubeconfig  — written by `ssm pod`. Your ~/.kube/config is never touched.

EOF
}

# Sourcing the script (the test suite does) must not run a command.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  COMMAND="$1"
  [[ $# -gt 0 ]] && shift

  # No command: ask, but only when there is someone there to ask and something
  # to ask with. Piped, redirected, or without fzf, bare `ssm` keeps printing
  # the usage line and exiting 1 the way it always has, so nothing scripted
  # against it changes and nothing ever blocks on a menu nobody can see.
  if [[ -z "$COMMAND" && -t 0 && -t 1 ]] && command -v fzf &>/dev/null; then
    COMMAND=$(cmd_menu) || exit 0
  fi

  case "$COMMAND" in
    ssh)    cmd_ssh "$@" ;;
    pod)    cmd_pod "$@" ;;
    db)     cmd_db "$@" ;;
    config) cmd_config "$@" ;;
    update) cmd_update "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    version|--version) cmd_version "$@" ;;
    help)   cmd_help ;;
    -h|--help) cmd_help ;;
    *)
      echo "Usage: ssm [ssh|pod|db|config|update|uninstall|version|help] [flags]" >&2
      echo "Run 'ssm help' for the full flag reference." >&2
      exit 1
      ;;
  esac
fi
