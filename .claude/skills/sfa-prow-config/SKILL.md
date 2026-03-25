---
name: sfa-prow-config
description: "Get stolostron prow configuration and version mapping information. Use this skill when you need to know about OpenShift release config, ACM/MCE/OCP version relationships, or stolostron repository ownership for prow testing. For example: `What OCP version corresponds to ACM 2.14?` or `Who owns the cluster-proxy repo in prow config?` or `What's the MCE version for ACM release-2.14?`"
---

# Prow Configuration Skill

This skill provides information about OpenShift prow configuration, version mappings, and repository ownership for the ACM server foundation squad.

## Repository Information

### OpenShift Release Config
- Repository: https://github.com/openshift/release
- This is where prow CI/CD configuration is maintained for testing ACM/MCE on OCP

### Prow Config Structure
For each stolostron repository, prow configurations are organized by branch in the OpenShift release repo:
- Path pattern: `ci-operator/config/stolostron/<repo-name>/`
- Example: https://github.com/openshift/release/tree/main/ci-operator/config/stolostron/ocm

Each repository has separate config files for:
- **Y-stream branches**: `release-2.y` branches (e.g., release-2.13, release-2.14, release-2.15)
- **Main branch**: The `main` branch config should align with the latest y-stream branch's OCP version

**Important**:
- When updating configs, ensure the main branch uses the same OCP version as the latest y-stream release branch.
- **Only the latest 6 y-stream branches and the main branch are actively supported**
- Do not update older branches beyond the latest 6 when making prow config changes

## Version Mapping

The ACM, MCE, and OCP versions have the following relationship:

### Current Mapping Rules

**For ACM version <= 2.16:**
- **ACM version**: `release-2.y` (e.g., release-2.14)
- **MCE version**: `backplane-2.(y-5)` (e.g., backplane-2.9 when ACM is 2.14)
- **OCP version**: `4.(y+5)` (e.g., 4.19 when ACM is 2.14)

**For ACM version >= 2.17:**
- **ACM version**: `release-2.y` (e.g., release-2.17)
- **MCE version**: `backplane-2.y` (e.g., backplane-2.17 when ACM is 2.17) - **MCE now matches ACM version**
- **OCP version**: `4.(y+5)` (e.g., 4.22 when ACM is 2.17)

**Future versioning (planned):**
- ACM and MCE version will jump directly to `5.y` to align with OCP 5.x releases

### Formula
- If ACM is `release-2.y` where **y <= 16**:
  - MCE is `backplane-2.(y-5)`
  - OCP is `4.(y+5)`

- If ACM is `release-2.y` where **y >= 17**:
  - MCE is `backplane-2.y` (matches ACM version)
  - OCP is `4.(y+5)`

### Examples

**Legacy mapping (ACM <= 2.16):**
- ACM release-2.14 -> MCE backplane-2.9 -> OCP 4.19
- ACM release-2.13 -> MCE backplane-2.8 -> OCP 4.18
- ACM release-2.15 -> MCE backplane-2.10 -> OCP 4.20
- ACM release-2.16 -> MCE backplane-2.11 -> OCP 4.21

**New mapping (ACM >= 2.17):**
- ACM release-2.17 -> MCE backplane-2.17 -> OCP 4.22
- ACM release-2.18 -> MCE backplane-2.18 -> OCP 4.23

## Stolostron Repository Ownership

The following stolostron repositories are maintained by the ACM server foundation squad with their respective owners:

| Repository | Owners |
|------------|--------|
| stolostron/ocm | zhujian7, xuezhaojun |
| stolostron/managed-serviceaccount | zhujian7, xuezhaojun |
| stolostron/multicloud-operators-foundation | elgnay |
| stolostron/managedcluster-import-controller | xuezhaojun |
| stolostron/cluster-proxy | xuezhaojun |
| stolostron/clusterlifecycle-state-metrics | haoqing0110 |
| stolostron/klusterlet-addon-controller | zhujian7, zhiweiyin318 |
| stolostron/cluster-permission | zhiweiyin318 |

## Updating OCP Versions in Prow Configs

When you need to update OCP versions for server foundation repos in the OpenShift release repository:

### Prerequisites
- Working directory: `/path/to/openshift/release` repository
- Only update **latest 6 y-stream branches + main** for each repo

### Step-by-Step Process

1. **Identify which repos to update**
   - Use the SF repos list from the "Stolostron Repository Ownership" section above
   - Only update repos that are owned by the server foundation team

2. **Determine correct OCP versions**
   - **Simplified formulas:**
     - **For ACM <= 2.16:** MCE backplane-2.y -> OCP 4.(y+10), ACM release-2.y -> OCP 4.(y+5)
     - **For ACM >= 2.17:** MCE backplane-2.y -> OCP 4.(y+5), ACM release-2.y -> OCP 4.(y+5)
   - **For main branch:**
     - MCE repos: Same as latest backplane-2.x (currently backplane-2.17 -> OCP 4.22)
     - ACM repos: Same as latest release-2.x (currently release-2.17 -> OCP 4.22)

3. **Update config files**
   - Location: `ci-operator/config/stolostron/<repo-name>/`
   - Files to update: Only main + latest 6 y-stream branches
   - Pattern to change: In the `releases` section, update `name: "X.Y"` under both `initial` and `latest`

   Example:
   ```yaml
   releases:
     initial:
       integration:
         name: "4.14"  # Update this
         namespace: ocp
     latest:
       integration:
         include_built_images: true
         name: "4.14"  # Update this
         namespace: ocp
   ```

4. **Regenerate downstream artifacts**
   ```bash
   make update
   ```
   This will regenerate Prow job configs and other generated files.

5. **Validate changes**
   ```bash
   make checkconfig
   ```

### Important Rules

- DO update only the latest 6 y-stream branches and main
- DO verify changes with `git diff` before running `make update`
- DO follow the version mapping formula strictly
- DO NOT update branches older than the latest 6
- DO NOT manually edit files in `ci-operator/jobs/` - they are auto-generated
- DO NOT update non-SF repos unless explicitly requested

### Example Version Mappings

**Note:**
- **ACM <= 2.16:** MCE backplane-2.y <-> ACM release-2.(y+5)
- **ACM >= 2.17:** MCE backplane-2.y <-> ACM release-2.y (versions now match)

| Branch | Correct OCP Version | Notes |
|--------|---------------------|-------|
| backplane-2.6 | 4.16 | Legacy mapping |
| backplane-2.7 | 4.17 | Legacy mapping |
| backplane-2.8 | 4.18 | Legacy mapping |
| backplane-2.9 | 4.19 | Legacy mapping |
| backplane-2.10 | 4.20 | Legacy mapping |
| backplane-2.11 | 4.21 | Legacy mapping |
| backplane-2.17 | 4.22 | New mapping (matches ACM) |
| backplane-2.18 | 4.23 | New mapping (matches ACM) |
| release-2.11 | 4.16 | Legacy mapping |
| release-2.12 | 4.17 | Legacy mapping |
| release-2.13 | 4.18 | Legacy mapping |
| release-2.14 | 4.19 | Legacy mapping |
| release-2.15 | 4.20 | Legacy mapping |
| release-2.16 | 4.21 | Legacy mapping (last before change) |
| release-2.17 | 4.22 | New mapping |
| release-2.18 | 4.23 | New mapping |
| main | 4.22 | Follows latest release |

## Usage

When asked about prow configuration, version mappings, or repository ownership:
1. Reference the version mapping formulas above
2. Look up repository owners from the table
3. Point to the OpenShift release repository for prow config details
4. For OCP version updates, follow the "Updating OCP Versions in Prow Configs" process above
