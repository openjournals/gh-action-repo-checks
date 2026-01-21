# Open Journals :: Repository and paper checks

This action runs several checks on the software repository submitted for review to Open Journals:

- **A repo information summary**: This check performs an analysis of the source code and post back to the issue a list of authors, contributions and file types information.
- **Detect languages**: This will detect the languages used in the repository and label the issue with the top three used languages.
- **Detect license**: This will look for an Open Source License in the target repo and post the result as a comment in the issue.

The action also looks for a `paper.md` file in the specified repository and post back information on:

- **Wordcount**: This will count the number of words in the paper file.
- **Detect statement of need**: This check will look for a `Statement of need` section in the paper content.
- **Detect state of the field section**: For submissions without the `pre-2026-submission` label, this check will look for a `State of the Field` section in the paper.
- **Detect software design section**: For submissions without the `pre-2026-submission` label, this check will look for a `Software design` section in the paper.
- **Detect research impact statement**: For submissions without the `pre-2026-submission` label, this check will look for a `Research impact statement` section in the paper.
- **Detect AI usage disclosure**: For submissions without the `pre-2026-submission` label, this check will look for an `AI usage disclosure` section in the paper.


## Usage

Usually this action is used as a step in a workflow.

### Inputs

The action accepts the following inputs:

- **issue_id**: Required. The id of the review issue for the submission.
- **repository_url**: Required. The repository URL containing the software and the paper file.
- **branch**: Optional. Git branch where the paper is located.

### ENV

For the action to be able to add labels and post comments to the review issue there must be two env vars setted with valid values:

- **GITHUB_TOKEN**: The token of the user posting the results of the checks
- **GH_REPO**: The repository where the review issue is found, in `username/repo-name` format

### Example

Sample use as a step in a workflow `.yml` file in a repo's `.github/workflows/` directory, setting `env` and passing custom input values:

````yaml
name: Repository and paper info
on:
  workflow_dispatch:
    inputs:
      issue_id:
        description: 'The issue number of the submission to post the results'
env:
  GITHUB_TOKEN: ${{ secrets.BOT_USER_TOKEN }}
  GH_REPO: myorg/reviews
jobs:
  run-analysis:
    runs-on: ubuntu-latest
    steps:
      - name: Repository and paper analysis
        uses: openjournals/gh-action-repo-checks@main
        with:
          repository_url: http://github.com/${{ github.repository }}
          branch: paper
          issue_id: ${{ github.event.inputs.issue_id }}
```
