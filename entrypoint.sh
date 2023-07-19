#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_OWNER=$(jq -r .event.base.repo.owner /github/workflow/event.json)
REPO_NAME=$(jq -r .event.base.repo.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to pr-{number}-{repo_owner}-{repo_name}
app="${INPUT_NAME:-pr-$PR_NUMBER-$REPO_OWNER-$REPO_NAME}"
region="${INPUT_REGION:-${FLY_REGION:-iad}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
config="$INPUT_CONFIG"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# PR was closed - remove the Fly app if one exists and exit.
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  exit 0
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  flyctl apps create "$app" --org "$org"
  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi
  # Attach postgres cluster to the app if specified.
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl postgres attach -y --app "$app" "$INPUT_POSTGRES"
  fi
  # Initial deployment
  flyctl deploy --config "$config" --app "$app" --region "$region" --image "$image" --remote-only --strategy immediate
elif [ "$INPUT_UPDATE" != "false" ]; then
  # Deployment when the PR was updated
  flyctl deploy --config "$config" --app "$app" --region "$region" --image "$image"  --remote-only --strategy immediate
fi

if [ -n "$INPUT_CERT_HOSTNAME" ]; then
  if ! flyctl certs show --app "$app" ; then
    flyctl certs add -a "$app" "$INPUT_CERT_HOSTNAME"
  fi
fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=${INPUT_CERT_HOSTNAME:-$(jq -r .Hostname status.json)}
appid=$(jq -r .ID status.json)
echo "::set-output name=hostname::$hostname"
echo "::set-output name=url::https://$hostname"
echo "::set-output name=id::$appid"
