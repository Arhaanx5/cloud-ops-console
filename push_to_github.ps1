# Push to GitHub
cd D:\intelliJ2025\cloud-dashboard

if (-not (Test-Path ".git")) {
    git init -b main
}

git config user.name "Arhaanx5"
git config user.email "arhaanmashkoor9@gmail.com"

# Check remotes
$remote = git remote
if ($remote -notcontains "origin") {
    git remote add origin https://github.com/Arhaanx5/cloud-ops-console.git
} else {
    git remote set-url origin https://github.com/Arhaanx5/cloud-ops-console.git
}

git add .
git commit -m "feat(ops): initial commit for enterprise cloud operations console (weblogic + aws style)"
git push -u origin main --force
