#!/bin/bash

# Navigate to the Hugo blog content directory
cd /home/taz/docker/hugo

# Add all changes
git add .

# Commit changes with a timestamp
git commit -m "Automated commit - $(date +'%Y-%m-%d %H:%M:%S')"

# Push to the remote repository
git push origin master