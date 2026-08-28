#!/bin/bash

CONFIG_FILE="$HOME/.ssm/config.json"
COMMAND="$1"

if ! command -v fzf &>/dev/null; then
  echo "Error: fzf is required but not installed. Run: brew install fzf"
  exit 1
fi

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

  printf '%s\n' "${items[@]}" | fzf --prompt="$prompt " --height=~10 --layout=reverse --border
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
  if ! aws ecs execute-command \
    --profile "$profile" \
    --region "$region" \
    --cluster "$cluster" \
    --task "$task" \
    --container "$container" \
    --interactive \
    --command "/bin/bash"; then
    echo "" >&2
    echo "Retrying with /bin/sh ..." >&2
    aws ecs execute-command \
      --profile "$profile" \
      --region "$region" \
      --cluster "$cluster" \
      --task "$task" \
      --container "$container" \
      --interactive \
      --command "/bin/sh"
  fi
}

ecs_pick_and_exec() {
  local profile="$1" region="$2"
  shift 2
  local rows=("$@")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running ECS tasks found." >&2
    exit 1
  fi

  local selected
  if [[ ${#rows[@]} -eq 1 ]]; then
    selected="${rows[0]}"
    echo "Auto-selecting: $selected" >&2
  else
    selected=$(select_menu "Select container:" "${rows[@]}")
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

  ecs_pick_and_exec "$profile" "$region" "${rows[@]}"
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

  ecs_pick_and_exec "$profile" "$region" "${rows[@]}"
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
  local accounts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && accounts+=("$line")
  done < <(list_accounts)

  if [[ ${#accounts[@]} -eq 0 ]]; then
    echo "No accounts found in $CONFIG_FILE" >&2
    exit 1
  fi

  select_menu "Select account:" "${accounts[@]}"
}

pick_app() {
  local profile="$1" region="$2"
  echo "Fetching apps..." >&2

  local apps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && apps+=("$line")
  done < <({ list_apps "$profile" "$region"; list_ecs_apps; } | sort -u | grep -v -e '^$' -e '^None$')

  if [[ ${#apps[@]} -eq 0 ]]; then
    echo "No running instances or ECS services with an App tag found." >&2
    exit 1
  fi

  select_menu "Select application:" "${apps[@]}"
}

pick_instance() {
  local profile="$1" region="$2" app="$3"
  echo "Fetching instances for $app..." >&2

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_instances "$profile" "$region" "$app")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running instances found for app: $app" >&2
    exit 1
  fi

  local selected
  if [[ ${#rows[@]} -eq 1 ]]; then
    selected="${rows[0]}"
    echo "Auto-selecting: $selected" >&2
  else
    selected=$(select_menu "Select instance:" "${rows[@]}")
  fi

  echo "$selected" | awk '{print $1}'
}

cmd_ssh() {
  local ACCOUNT PROFILE REGION APP INSTANCE_ID

  ACCOUNT=$(pick_account)
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")

  # Runs in this shell, not a subshell, so pick_app below inherits ECS_SERVICES.
  discover_ecs_services "$PROFILE" "$REGION"

  APP=$(pick_app "$PROFILE" "$REGION")

  # If the app also has ECS services, offer the choice. An app backed only by
  # EC2 skips this entirely and follows the original flow.
  if [[ -n "$(ecs_services_for_app "$APP")" ]]; then
    local target="ECS task"
    if [[ -n "$(list_instances "$PROFILE" "$REGION" "$APP")" ]]; then
      target=$(select_menu "Connect to:" "EC2 instance" "ECS task")
      [[ -z "$target" ]] && exit 0
    fi
    if [[ "$target" == "ECS task" ]]; then
      ssh_ecs_app "$PROFILE" "$REGION" "$APP"
      return
    fi
  fi

  INSTANCE_ID=$(pick_instance "$PROFILE" "$REGION" "$APP")

  # Autocheck: is this a plain EC2 box or an ECS container instance?
  local ecs_node cluster ci_arn shell_choice
  ecs_node=$(detect_ecs_container_instance "$PROFILE" "$REGION" "$INSTANCE_ID")
  if [[ -n "$ecs_node" ]]; then
    cluster=$(echo "$ecs_node" | awk -F'\t' '{print $1}')
    ci_arn=$(echo "$ecs_node" | awk -F'\t' '{print $2}')
    echo "" >&2
    echo "This instance is an ECS container instance in cluster $cluster." >&2
    shell_choice=$(select_menu "Open which shell?" "Host shell (sudo su - ubuntu)" "Container shell (ECS Exec)")
    [[ -z "$shell_choice" ]] && exit 0
    if [[ "$shell_choice" == "Container shell (ECS Exec)" ]]; then
      ssh_ecs_container_instance "$PROFILE" "$REGION" "$cluster" "$ci_arn"
      return
    fi
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
  local profile="$1" region="$2"
  echo "Fetching EKS clusters..." >&2

  local clusters=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && clusters+=("$line")
  done < <(list_eks_clusters "$profile" "$region")

  if [[ ${#clusters[@]} -eq 0 ]]; then
    echo "No EKS clusters found in $region." >&2
    exit 1
  fi

  if [[ ${#clusters[@]} -eq 1 ]]; then
    echo "Auto-selecting: ${clusters[0]}" >&2
    echo "${clusters[0]}"
  else
    select_menu "Select cluster:" "${clusters[@]}"
  fi
}

pick_namespace() {
  echo "Fetching namespaces..." >&2

  local namespaces=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && namespaces+=("$line")
  done < <(list_namespaces)

  if [[ ${#namespaces[@]} -eq 0 ]]; then
    echo "No namespaces found. Check your access to this cluster." >&2
    exit 1
  fi

  select_menu "Select namespace:" "${namespaces[@]}"
}

pick_pod() {
  local namespace="$1"
  echo "Fetching pods in $namespace..." >&2

  local rows=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done < <(list_pods "$namespace")

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No running pods found in namespace: $namespace" >&2
    exit 1
  fi

  local selected
  if [[ ${#rows[@]} -eq 1 ]]; then
    selected="${rows[0]}"
    echo "Auto-selecting: $selected" >&2
  else
    selected=$(select_menu "Select pod:" "${rows[@]}")
  fi

  echo "$selected" | awk -F'\t' '{print $1}'
}

pick_pod_container() {
  local namespace="$1" pod="$2"

  local containers=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && containers+=("$line")
  done < <(list_pod_containers "$namespace" "$pod")

  if [[ ${#containers[@]} -eq 0 ]]; then
    echo "No containers found in pod: $pod" >&2
    exit 1
  fi

  if [[ ${#containers[@]} -eq 1 ]]; then
    echo "Auto-selecting container: ${containers[0]}" >&2
    echo "${containers[0]}"
  else
    select_menu "Select container:" "${containers[@]}"
  fi
}

cmd_pod() {
  local ACCOUNT PROFILE REGION CLUSTER NAMESPACE POD CONTAINER

  require_kubectl

  ACCOUNT=$(pick_account)
  [[ -z "$ACCOUNT" ]] && exit 0
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")

  CLUSTER=$(pick_eks_cluster "$PROFILE" "$REGION")
  [[ -z "$CLUSTER" ]] && exit 0

  use_eks_cluster "$PROFILE" "$REGION" "$CLUSTER"

  NAMESPACE=$(pick_namespace)
  [[ -z "$NAMESPACE" ]] && exit 0

  POD=$(pick_pod "$NAMESPACE")
  [[ -z "$POD" ]] && exit 0

  CONTAINER=$(pick_pod_container "$NAMESPACE" "$POD")
  [[ -z "$CONTAINER" ]] && exit 0

  kubectl_exec "$NAMESPACE" "$POD" "$CONTAINER"
}

cmd_db() {
  local ACCOUNT PROFILE REGION APP
  local DB_IDENTIFIER RDS_HOST LOCAL_PORT
  local INSTANCE_ID DB_ALIAS

  ACCOUNT=$(pick_account)
  PROFILE=$(load_config "$ACCOUNT" "profile")
  REGION=$(load_config "$ACCOUNT" "region")
  APP=$(pick_app "$PROFILE" "$REGION")

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
  if [[ ${#rds_rows[@]} -eq 1 ]]; then
    selected_rds="${rds_rows[0]}"
    echo "Auto-selecting RDS: $selected_rds" >&2
  else
    selected_rds=$(select_menu "Select database:" "${rds_rows[@]}")
  fi

  DB_IDENTIFIER=$(echo "$selected_rds" | awk '{print $1}')
  RDS_HOST=$(echo "$selected_rds" | awk '{print $2}')
  RDS_PORT=$(echo "$selected_rds" | awk '{print $3}')
  LOCAL_PORT=$(get_db_port "$ACCOUNT" "$DB_IDENTIFIER")

  echo "Fetching jump-host for $APP..." >&2
  INSTANCE_ID=$(list_instances "$PROFILE" "$REGION" "$APP" | awk 'NR==1{print $1}')
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
  local action
  action=$(select_menu "Config action:" "view" "add" "edit" "delete")
  [[ -z "$action" ]] && exit 0

  case "$action" in
    view)   config_view ;;
    add)    config_add ;;
    edit)   config_edit ;;
    delete) config_delete ;;
  esac
}

aws_profile_configure() {
  local profile="$1" key="$2" secret="$3" region="$4"
  aws configure set aws_access_key_id     "$key"    --profile "$profile"
  aws configure set aws_secret_access_key "$secret" --profile "$profile"
  aws configure set region                "$region" --profile "$profile"
  aws configure set output                "json"    --profile "$profile"
}

config_view() {
  jq '.' "$CONFIG_FILE"

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
  done < <(list_accounts)
}

config_add() {
  local name profile region
  read -r -p "Account name: " name
  [[ -z "$name" ]] && { echo "Aborted." >&2; return; }
  read -r -p "AWS profile: " profile
  read -r -p "AWS region: " region

  local updated
  updated=$(jq ".[\"$name\"] = {\"profile\": \"$profile\", \"region\": \"$region\", \"databases\": {}}" "$CONFIG_FILE")
  echo "$updated" > "$CONFIG_FILE"
  echo "Account '$name' added."

  read -r -p "Set up AWS CLI credentials for profile '$profile'? [y/N]: " setup
  if [[ "$setup" == "y" || "$setup" == "Y" ]]; then
    local key secret
    read -r -p "Access Key ID: " key
    read -r -s -p "Secret Access Key: " secret
    echo ""
    aws_profile_configure "$profile" "$key" "$secret" "$region"
    echo "AWS CLI profile '$profile' configured."
  fi
}

config_delete() {
  local account updated
  account=$(pick_account)
  [[ -z "$account" ]] && exit 0

  read -r -p "Delete account '$account'? [y/N]: " confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted." >&2; return; }

  local profile
  profile=$(load_config "$account" "profile")

  updated=$(jq "del(.[\"$account\"])" "$CONFIG_FILE")
  echo "$updated" > "$CONFIG_FILE"
  echo "Account '$account' deleted."

  read -r -p "Also delete AWS CLI profile '$profile'? [y/N]: " del_profile
  if [[ "$del_profile" == "y" || "$del_profile" == "Y" ]]; then
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

  account=$(pick_account)
  [[ -z "$account" ]] && exit 0

  field=$(select_menu "Select field to edit:" "profile" "region" "aws-access-key" "aws-secret-key")
  [[ -z "$field" ]] && exit 0

  profile=$(load_config "$account" "profile")

  case "$field" in
    profile|region)
      local current value updated
      current=$(load_config "$account" "$field")
      read -r -p "$field [$current]: " value
      value="${value:-$current}"
      updated=$(jq ".[\"$account\"][\"$field\"] = \"$value\"" "$CONFIG_FILE")
      echo "$updated" > "$CONFIG_FILE"
      echo "Updated $account.$field → '$value'."
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
      read -r -s -p "New Secret Access Key: " value
      echo ""
      [[ -z "$value" ]] && { echo "Aborted." >&2; return; }
      aws configure set aws_secret_access_key "$value" --profile "$profile"
      echo "Updated AWS secret key for profile '$profile'."
      ;;
  esac
}

cmd_update() {
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

cmd_help() {
  cat <<'EOF'

USAGE
  ssm ssh      — Shell into an EC2 instance, an ECS container instance, or an
                 ECS/Fargate container. Detects ECS nodes and asks whether you
                 want the host shell or a container shell.
  ssm pod      — Shell into an EKS pod via kubectl (cluster → namespace → pod)
  ssm db       — Open an RDS tunnel via SSM port forwarding
  ssm config   — View, add, or edit AWS account profiles
  ssm update   — Replace this script with the latest version from CDN

CONFIG FILE
  ~/.ssm/config.json — maps account names to AWS CLI profiles and regions.
  DB port assignments are auto-saved here on first use.
  ~/.ssm/kubeconfig  — written by `ssm pod`. Your ~/.kube/config is never touched.

EOF
}

case "$COMMAND" in
  ssh)    cmd_ssh ;;
  pod)    cmd_pod ;;
  db)     cmd_db ;;
  config) cmd_config ;;
  update) cmd_update ;;
  help)   cmd_help ;;
  *)
    echo "Usage: ssm [ssh|pod|db|config|update|help]"
    exit 1
    ;;
esac
