# process_bot_prs.jq — Phase 2: Filter raw PRs to open bot PRs
#
# Usage:
#   jq --argjson today_sec $(date +%s) -f workflows/weekly-bot-pr-report/process_bot_prs.jq <raw_prs.json>
#
# Input:  Raw JSON array from fetch-prs skill (detail level: all)
# Output: Filtered array of open bot PRs with flat fields

def is_bot:
  .login as $l |
  ($l == "red-hat-konflux" or $l == "dependabot" or $l == "renovate" or ($l | endswith("[bot]")) or ($l | endswith("-bot")));

def days_since_created:
  ($today_sec - (.content.createdAt | fromdateiso8601 | floor)) / 86400 | floor;

def extract_branch:
  # Try to extract branch from PR title parentheses, e.g., "Update x/crypto (backplane-2.9)"
  # Fall back to head branch ref name
  if (.content.title | test("\\(([^)]+)\\)\\s*$")) then
    .content.title | capture("\\((?<branch>[^)]+)\\)\\s*$") | .branch
  elif .content.headRefName then
    .content.headRefName
  else
    "unknown"
  end;

map(select(.content.state == "OPEN" and (.content.author | is_bot))) |
map(
  .age_days = days_since_created |
  .author = (.content.author.login // "unknown") |
  .repo = .content.repository.nameWithOwner |
  .short_repo = (.content.repository.nameWithOwner | sub("^[^/]+/"; "")) |
  .title = .content.title |
  .url = .content.url |
  .number = .content.number |
  .branch = extract_branch |
  .is_fork = (.content.isCrossRepository // false)
)
