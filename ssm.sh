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
  done < <(list_apps "$profile" "$region")

  if [[ ${#apps[@]} -eq 0 ]]; then
    echo "No running instances with an App tag found." >&2
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
  APP=$(pick_app "$PROFILE" "$REGION")
  INSTANCE_ID=$(pick_instance "$PROFILE" "$REGION" "$APP")

  echo "" >&2
  echo "Connecting to $INSTANCE_ID via SSM ..."
  aws ssm start-session \
    --profile "$PROFILE" \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartInteractiveCommand \
    --parameters '{"command": ["sudo su - ubuntu"]}'
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
  ssm ssh      — SSH into an EC2 instance via SSM
  ssm db       — Open an RDS tunnel via SSM port forwarding
  ssm config   — View, add, or edit AWS account profiles
  ssm update   — Replace this script with the latest version from CDN

CONFIG FILE
  ~/.ssm/config.json — maps account names to AWS CLI profiles and regions.
  DB port assignments are auto-saved here on first use.

EOF
}

case "$COMMAND" in
  ssh)    cmd_ssh ;;
  db)     cmd_db ;;
  config) cmd_config ;;
  update) cmd_update ;;
  help)   cmd_help ;;
  *)
    echo "Usage: ssm [ssh|db|config|update|help]"
    exit 1
    ;;
esac
