#!/bin/bash

CONFIG_FILE="$HOME/.ssm/config.json"
# Set by the dispatch block at the bottom. Only used to name the command in
# error and usage messages.
COMMAND=""

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed. Run: brew install jq"
  exit 1
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
  local items=("$@")

  # Checked here rather than at startup: a fully-flagged run never opens a menu,
  # and neither do `ssm help` or `ssm update`.
  if ! command -v fzf &>/dev/null; then
    echo "Error: fzf is required but not installed. Run: brew install fzf" >&2
    return 1
  fi

  printf '%s\n' "${items[@]}" | fzf --prompt="$prompt " --height=~10 --layout=reverse --border
}

# ---------------------------------------------------------------------------
# Argument handling. Every interactive prompt has a flag that replaces it; a
# flag you leave out falls back to its menu, so bare `ssm ssh` is unchanged.
# ---------------------------------------------------------------------------

# Every flag the script knows about, in any command. parse_args clears all of
# them on entry so a second call in the same shell starts clean.
ALL_ARG_FLAGS="env app type instance container task host db cluster namespace \
pod profile region access-key secret-key skip-credentials yes delete-profile"

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
      echo "Auto-selecting: ${rows[0]}" >&2
      printf '%s\n' "${rows[0]}"
    else
      select_menu "$prompt" "${rows[@]}"
    fi
    return $?
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

pick_account() {
  local wanted="$1"
  local accounts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && accounts+=("$line")
  done < <(list_accounts)

  if [[ ${#accounts[@]} -eq 0 ]]; then
    echo "No accounts found in $CONFIG_FILE" >&2
    return 1
  fi

  resolve_selection "$wanted" "account" "$CONFIG_FILE" "Select account:" 1 "" "${accounts[@]}"
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
  if [[ "$ARG_TYPE" == "ec2" || -n "$ARG_INSTANCE" ]]; then
    printf '%s' "EC2 instance"
  elif [[ "$ARG_TYPE" == "ecs" || -n "$ARG_CONTAINER" || -n "$ARG_TASK" ]]; then
    printf '%s' "ECS task"
  else
    select_menu "Connect to:" "EC2 instance" "ECS task"
  fi
}

# The "Open which shell?" menu on an ECS container instance, or its flags.
ssh_pick_shell() {
  if [[ -n "$ARG_HOST" ]]; then
    printf '%s' "Host shell"
  elif [[ -n "$ARG_CONTAINER" || -n "$ARG_TASK" ]]; then
    printf '%s' "Container shell (ECS Exec)"
  else
    select_menu "Open which shell?" "Host shell" "Container shell (ECS Exec)"
  fi
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
  if ! grep -qF "127.0.0.1 $DB_ALIAS" /etc/hosts; then
    echo "Adding $DB_ALIAS to /etc/hosts (requires sudo) ..."
    echo "127.0.0.1 $DB_ALIAS" | sudo tee -a /etc/hosts > /dev/null
  fi

  cleanup() {
    echo ""
    echo "Removing $DB_ALIAS from /etc/hosts ..."
    sudo sed -i '' "/127.0.0.1 $DB_ALIAS/d" /etc/hosts
  }
  trap cleanup EXIT

  local params
  params=$(jq -n \
    --arg host "$RDS_HOST" \
    --arg port "$RDS_PORT" \
    --arg local "$LOCAL_PORT" \
    '{"host":[$host],"portNumber":[$port],"localPortNumber":[$local]}')

  echo ""
  echo "Connect to: ${DB_ALIAS}:${LOCAL_PORT}"
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

  parse_args "--env --profile --region --access-key --secret-key" \
    "--skip-credentials --yes --delete-profile" "$@" || exit 1

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
  [[ -z "$name" ]] && read -r -p "Account name: " name
  [[ -z "$name" ]] && { echo "Aborted." >&2; return 1; }

  profile="$ARG_PROFILE"
  [[ -z "$profile" ]] && read -r -p "AWS profile: " profile
  region="$ARG_REGION"
  [[ -z "$region" ]] && read -r -p "AWS region: " region

  local updated
  updated=$(jq ".[\"$name\"] = {\"profile\": \"$profile\", \"region\": \"$region\", \"databases\": {}}" "$CONFIG_FILE")
  echo "$updated" > "$CONFIG_FILE"
  echo "Account '$name' added."

  [[ -n "$ARG_SKIP_CREDENTIALS" ]] && return 0

  local key secret
  # Credentials supplied on the command line mean there is nothing to ask.
  if [[ -n "$ARG_ACCESS_KEY" || -n "$ARG_SECRET_KEY" || -n "$SSM_AWS_SECRET_KEY" ]]; then
    key="$ARG_ACCESS_KEY"
    [[ -z "$key" ]] && read -r -p "Access Key ID: " key
    secret=$(read_secret_value "$ARG_SECRET_KEY") || return 1
    aws_profile_configure "$profile" "$key" "$secret" "$region"
    echo "AWS CLI profile '$profile' configured."
    return 0
  fi

  local setup
  read -r -p "Set up AWS CLI credentials for profile '$profile'? [y/N]: " setup
  if [[ "$setup" == "y" || "$setup" == "Y" ]]; then
    read -r -p "Access Key ID: " key
    secret=$(read_secret_value "") || return 1
    aws_profile_configure "$profile" "$key" "$secret" "$region"
    echo "AWS CLI profile '$profile' configured."
  fi
}

config_delete() {
  local account updated
  account=$(pick_account "$ARG_ENV") || exit 1
  [[ -z "$account" ]] && exit 0

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
  if [[ -n "$ARG_PROFILE" || -n "$ARG_REGION" || -n "$ARG_ACCESS_KEY" \
     || -n "$ARG_SECRET_KEY" || -n "$SSM_AWS_SECRET_KEY" ]]; then
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
    return 0
  fi

  field=$(select_menu "Select field to edit:" "profile" "region" "aws-access-key" "aws-secret-key")
  [[ -z "$field" ]] && exit 0

  case "$field" in
    profile|region)
      local current value
      current=$(load_config "$account" "$field")
      read -r -p "$field [$current]: " value
      value="${value:-$current}"
      config_set_field "$account" "$field" "$value"
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

cmd_update() {
  parse_args "" "" "$@" || exit 1

  local SSM_SCRIPT="$HOME/.ssm/ssm.sh"
  local CDN_URL="https://cdn.supplycart.my/shells/ssm.sh"

  echo "Downloading latest ssm.sh from CDN..."
  if curl -fsSL "$CDN_URL" -o "$SSM_SCRIPT"; then
    chmod +x "$SSM_SCRIPT"
    echo "ssm updated successfully."
  else
    echo "Update failed. Could not download from $CDN_URL" >&2
    exit 1
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
EOF
      ;;
    config)
      cat <<'EOF'
ssm config — Manage account profiles and AWS CLI credentials.

  ssm config [view|add|edit|delete] [flags]      (no action: pick from a menu)

  ssm config view   [--env <name>]
  ssm config add    --env <name> [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -] [--skip-credentials]
  ssm config edit   --env <name> [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -]
  ssm config delete --env <name> [--yes] [--delete-profile]

  --yes             skip the delete confirmation
  --delete-profile  also remove the profile from ~/.aws/credentials and config

Never pass a secret as a flag value -- it lands in your shell history. Set
SSM_AWS_SECRET_KEY=... or use '--secret-key -' to read one line from stdin.
EOF
      ;;
    *)
      cmd_help
      ;;
  esac
}

cmd_help() {
  cat <<'EOF'

USAGE
  ssm <command> [flags]      every flag you omit falls back to its menu

  ssm ssh      Shell into an EC2 instance, an ECS container instance, or an
               ECS/Fargate container. Detects ECS nodes and asks whether you
               want the host shell or a container shell.
  ssm pod      Shell into an EKS pod via kubectl (cluster -> namespace -> pod)
  ssm db       Open an RDS tunnel via SSM port forwarding
  ssm config   View, add, edit, or delete AWS account profiles
  ssm update   Replace this script with the latest version from CDN
  ssm help     Show this text

  Run `ssm <command> --help` for that command's flags.

FLAGS
  ssm ssh      [--env <name>] [--app <name>] [--type ec2|ecs]
               [--instance <id|Name>] [--container <name>] [--task <id>] [--host]
  ssm pod      [--env <name>] [--cluster <name>] [-n <namespace>]
               [--pod <name>] [-c <container>]
  ssm db       [--env <name>] [--app <name>] [--db <identifier>]
               [--instance <id|Name>]
  ssm config   [view|add|edit|delete] [flags]

EXAMPLES
  ssm ssh                                     fully interactive, as before
  ssm ssh --env staging                       skips the account menu
  ssm ssh --env staging --app adam            no prompts if the app has one instance
  ssm ssh --env staging --app adam --container php-fpm
  ssm db  --env staging --app adam --db sc-staging-adam-rds
  ssm pod --env staging -n default --pod api-7d9f
  ssm config add --env staging --profile sc-staging --region ap-southeast-5

  A value that does not exist is an error listing the valid ones, so a fully
  flagged command never stops to ask a question.

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

  case "$COMMAND" in
    ssh)    cmd_ssh "$@" ;;
    pod)    cmd_pod "$@" ;;
    db)     cmd_db "$@" ;;
    config) cmd_config "$@" ;;
    update) cmd_update "$@" ;;
    help)   cmd_help ;;
    -h|--help) cmd_help ;;
    *)
      echo "Usage: ssm [ssh|pod|db|config|update|help] [flags]" >&2
      echo "Run 'ssm help' for the full flag reference." >&2
      exit 1
      ;;
  esac
fi
