# ia-usage-mac-widget

## Git workflow

- **Always confirm the branch first.** Before starting any task, check the current branch and ask the user which branch to use — don't assume, even when one looks obviously right. A stale branch, or another session's branch mid-task, can look plausible and still be wrong.
- **Branch per task, cut from `master` only.**
  ```
  git checkout master && git pull && git checkout -b task/<name>
  ```
- **Never commit directly to `master`.** All work happens on a task branch. (This repo has no `beta` branch — a personal project with no staging deploy.)
- **Keep local `master` updated.** `git pull` it before cutting a new branch and before merging any PR into it.
- **Merging to `master` needs explicit permission.** Never merge a branch into `master` on your own judgment — open a PR (`gh pr create`) and ask the user before merging it. Merges to `master` go through GitHub, not a local `git merge`.
- **After a branch's PR merges, clean up.** Delete it locally and on GitHub, and switch back to `master` locally.
  ```
  git checkout master && git pull
  git branch -d task/<name>
  git push origin --delete task/<name>
  ```

## Before starting a task

See "Git workflow" above — check the current branch and ask the user which one to use before doing anything else.
