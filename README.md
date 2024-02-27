# gh-action-repo-checks
GitHub action to run checks on a repository and paper file submitted to Open Journals for review

This action can be used in a GitHub workflow to run these checks:

- **repo summary**: This check performs an analysis of the source code and list authorship, contributions and file types information.
- **languages**: This will detect the languages used in the repository and tagged the issue with the top three used languages.
- **wordcount**: This will count the number of words in the paper file.
- **license**: This will look for an Open Source License in the target repo and reply an error message if no license is found.
- **statement of need**: This check will look for an Statement of need section in the paper content.
