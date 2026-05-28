# Analyze Bug Reproducibility

Use these skills:

| Step | Skill | Purpose |
|------|-------|---------|
| 1. Analyze one bug | [sfa-bug-analyze](../.claude/skills/sfa-bug-analyze/SKILL.md) | SF relevance, reproducibility score (0–12), missing-info checklist |
| 2. Reproduce end-to-end | [sfa-bug-reproduce](../.claude/skills/sfa-bug-reproduce/SKILL.md) | Provision ACM/MCE, run test, post results, cleanup |

**Trigger phrases:** `analyze bug ACM-12345`, `check bug reproducibility`, `reproduce bug ACM-12345`

**Example:**

```bash
# Analysis only — follow sfa-bug-analyze/SKILL.md
# Full reproduction
.claude/skills/sfa-bug-reproduce/reproduce.sh --issue-key ACM-12345
```
