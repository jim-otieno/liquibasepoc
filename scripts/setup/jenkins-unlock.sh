#!/usr/bin/env bash
# Wait for the Jenkins controller (infra/jenkins) to finish installing, then print
# its URL and the one-time unlock password. Uses SSM Run Command: no SSH, no key.
#
#   bash scripts/setup/jenkins-unlock.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tf() { terraform -chdir="$ROOT/infra/jenkins" output -raw "$1" | tr -d '\r'; }
ID="$(tf instance_id)"
URL="$(tf jenkins_url)"
REGION="${AWS_REGION:-us-east-1}"

run() {  # run a shell command on the instance, print its stdout
  local cid
  cid="$(aws ssm send-command --region "$REGION" --instance-ids "$ID" \
          --document-name AWS-RunShellScript --parameters "commands=[\"$1\"]" \
          --query Command.CommandId --output text | tr -d '\r')"
  aws ssm wait command-executed --region "$REGION" --command-id "$cid" --instance-id "$ID" 2>/dev/null || true
  aws ssm get-command-invocation --region "$REGION" --command-id "$cid" --instance-id "$ID" \
      --query StandardOutputContent --output text | tr -d '\r'
}

echo "Waiting for the instance to register with SSM..."
for _ in $(seq 1 60); do
  s="$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=$ID" --query 'InstanceInformationList[0].PingStatus' --output text | tr -d '\r')"
  [ "$s" = "Online" ] && break
  sleep 10
done

echo "Waiting for Jenkins to finish installing (5-10 minutes on a fresh instance)..."
for _ in $(seq 1 60); do
  out="$(run 'test -f /var/lib/jenkins/secrets/initialAdminPassword && cat /var/lib/jenkins/secrets/initialAdminPassword || true')"
  if [ -n "${out//[[:space:]]/}" ]; then
    echo
    echo "Jenkins URL:      $URL"
    echo "Unlock password:  $out"
    exit 0
  fi
  # The setup wizard deletes the password file once an admin user exists.
  if run 'test -f /var/lib/jenkins-bootstrap.done && systemctl is-active -q jenkins && echo up' | grep -q up; then
    sleep 20   # Jenkins writes the password file a few seconds after it starts
    out="$(run 'cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || true')"
    if [ -z "${out//[[:space:]]/}" ]; then echo "Jenkins is already set up: $URL"; exit 0; fi
    continue
  fi
  sleep 15
done
echo "Timed out. Check the install log with:" >&2
echo "  aws ssm start-session --target $ID   then: sudo tail -50 /var/log/jenkins-bootstrap.log" >&2
exit 1
