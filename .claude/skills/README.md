# Skills

Skills are task-specific workflows the agent can execute. Each skill has a step-by-step checklist in its `SKILL.md`. All skills use the `sfa-` prefix (Server Foundation Agent) for discoverability.

| Skill | Description | Trigger |
|-------|-------------|---------|
| [sfa-github-fetch-prs](sfa-github-fetch-prs/SKILL.md) | Fetch all active PRs for the Server Foundation team | On demand |
| [sfa-workspace-clone](sfa-workspace-clone/SKILL.md) | Clone a repo and create a worktree for a PR or new branch (MUST use for all workspace checkouts) | On demand |
| [sfa-workspace-cleanup](sfa-workspace-cleanup/SKILL.md) | Remove workspace worktrees/clones whose PRs are merged/closed | On demand |
| [sfa-repo-sync](sfa-repo-sync/SKILL.md) | Initialize or update all submodules under repos/ to latest | On demand |
| [install-acm](install-acm/SKILL.md) | Install ACM/MCE on an OpenShift cluster (for testing and bug reproduction) | On demand |
| [uninstall-acm](uninstall-acm/SKILL.md) | Uninstall ACM from an OpenShift cluster (cleanup after testing) | On demand |
| [sfa-slack-notify](sfa-slack-notify/SKILL.md) | Send formatted notifications to Slack | On demand |
| [sfa-jira-search](sfa-jira-search/SKILL.md) | Search/list Jira issues for the SF team (supports team-wide and per-member queries) | On demand |
| [sfa-jira-create](sfa-jira-create/SKILL.md) | Create Jira issues in the ACM project with SF defaults | On demand |
| [sfa-jira-update](sfa-jira-update/SKILL.md) | Update Jira issue status (workflow transitions) and fields | On demand |
| [sfa-jira-comment](sfa-jira-comment/SKILL.md) | Add comments to Jira issues (PR links, progress updates) | On demand |
| [sfa-jira-inbox](sfa-jira-inbox/SKILL.md) | Check Jira inbox and manage action items (assigned, reported, mentioned) | On demand |
| [sfa-jira-standup](sfa-jira-standup/SKILL.md) | Generate daily standup report from Jira | On demand |
| [sfa-jira-triage](sfa-jira-triage/SKILL.md) | Generate bug triage report (new/unassigned bugs) | On demand |
| [sfa-jira-sprint-report](sfa-jira-sprint-report/SKILL.md) | Generate sprint health report with per-member breakdown | On demand |
| [sfa-update](sfa-update/SKILL.md) | Log session summary to updates.md (what was done, issues, limitations) | On demand |
| [sfa-cluster-pools](sfa-cluster-pools/SKILL.md) | Manage OCP cluster pools, cluster claims, hibernation, and AWS resource cleanup | On demand |
| [sfa-prow-config](sfa-prow-config/SKILL.md) | Prow config reference: ACM/MCE/OCP version mappings and SF repo ownership | On demand |
| [sfa-solution-add](sfa-solution-add/SKILL.md) | Add a new solution (错题本 entry) with credential scanning and grep-friendly format | On demand |
| [sfa-bug-analyze](sfa-bug-analyze/SKILL.md) | Analyze Jira bug for SF relevance and reproducibility scoring | On demand |
| [sfa-bug-reproduce](sfa-bug-reproduce/SKILL.md) | Orchestrate full bug reproduction: provision cluster, test, post results | On demand |
| [sfa-project-create](sfa-project-create/SKILL.md) | Create tasks (draft issues) or add Issues/PRs to the GitHub Projects board | On demand |
| [sfa-project-update](sfa-project-update/SKILL.md) | Update task status, priority, size, dates on the Projects board | On demand |
| [sfa-project-search](sfa-project-search/SKILL.md) | List/filter/query items on the Projects board | On demand |
| [sfa-project-sync](sfa-project-sync/SKILL.md) | Sync Jira issues to the GitHub Projects board | On demand |
| [sfa-project-report](sfa-project-report/SKILL.md) | Generate progress reports from board data, optionally send to Slack | On demand |

## Adding a New Skill

1. Create `.claude/skills/sfa-<category>-<name>/SKILL.md` with frontmatter (`name`, `description`) and a step-by-step checklist
2. Update this table
3. (Optional) Add a CronJob in `deploy/cronjobs/` if the skill should run on a schedule
4. Open a PR — the skill is available to the agent once merged
