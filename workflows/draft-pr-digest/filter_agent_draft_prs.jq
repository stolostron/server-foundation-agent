# Filter open agent PRs: sfa-assisted label OR acm-agent[bot] author.
#
# Usage:
#   jq -f workflows/draft-pr-digest/filter_agent_draft_prs.jq <raw_prs.json> > agent_prs.json
#
# Input: JSON array from fetch-prs.sh (detail level "all")
# Output: { "draft": [...], "ready_for_review": [...] } sorted oldest-first each

def has_label($name):
  [.labels[]?.name] | index($name) != null;

def is_agent_pr:
  has_label("sfa-assisted")
  or (.author.login | test("acm-agent"; "i"));

def normalize:
  {
    url,
    number,
    title,
    repo: .repository.nameWithOwner,
    author: .author.login,
    branch: .headRefName,
    createdAt,
    updatedAt,
    labels: [.labels[]?.name]
  };

{
  draft: (
    [.[]
     | select(is_agent_pr)
     | select(.isDraft == true)
     | normalize]
    | sort_by(.createdAt)
  ),
  ready_for_review: (
    [.[]
     | select(is_agent_pr)
     | select(.isDraft == false)
     | normalize]
    | sort_by(.createdAt)
  )
}
