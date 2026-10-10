# workflows

Shared GitHub Actions for my repos.

- `.github/workflows/deepseek-code-review.yml`: the DeepSeek PR review. This is the only real copy. Each repo calls it through a small file, so a fix here reaches every repo on its next PR.
- `templates/deepseek-code-review.yml`: the small file each repo carries.
- `scripts/setup-repo.ps1`: sets a repo up with the review caller, the `DEEPSEEK_API_KEY` secret (read from Windows Credential Manager), and Dependabot alerts plus security-fix PRs.

```powershell
.\scripts\setup-repo.ps1 <repo-name>
.\scripts\setup-repo.ps1 -SetKey     # store or replace the API key
```

This repo is public so public repos can call the review too. It holds no secrets.
